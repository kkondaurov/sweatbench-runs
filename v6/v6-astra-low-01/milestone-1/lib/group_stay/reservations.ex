defmodule GroupStay.Reservations do
  alias GroupStay.{Group, Repo}
  import Ecto.Query

  def batch(operations), do: Enum.map(operations, &process/1)

  def get(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.from_struct()
        |> Map.drop([:__meta__, :refunded_cents, :retained_cents])
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  defp process(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Acquire SQLite's write lock before reading a revision so competing writers
    # cannot both validate the same revision or race to create the same group.
    result =
      Repo.transaction(
        fn ->
          require_fields(op, ["operation_id", "type", "occurred_on", "group_id"])

          unless identifier?(op["operation_id"]) and identifier?(op["group_id"]),
            do: reject("invalid_operation")

          unless op["type"] in [
                   "open_group",
                   "record_cash_payment",
                   "reschedule_group",
                   "cancel_group"
                 ],
                 do: reject("invalid_operation")

          if op["type"] == "open_group", do: open(op), else: update(op)
        end,
        mode: :immediate
      )

    case result do
      {:ok, fields} -> Map.merge(fields, %{operation_id: id, status: "applied"})
      {:error, fields} -> Map.merge(fields, %{operation_id: id, status: "rejected"})
    end
  end

  defp open(op) do
    require_fields(op, [
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ])

    unless identifier?(op["guest_id"]) and identifier?(op["property_id"]),
      do: reject("invalid_operation")

    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    booked = date!(op["occurred_on"], "invalid_operation")
    arrival = date!(op["arrival_on"], "invalid_stay")
    departure = date!(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    if nights < 1, do: reject("invalid_stay")
    rooms = op["rooms"]

    unless is_list(rooms) and rooms != [] and Enum.all?(rooms, &valid_room?/1),
      do: reject("invalid_rooms")

    ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(ids)) != length(ids), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")
    amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    # SQLite stores monetary totals as signed 64-bit integers.
    if Enum.sum(amounts) > 9_223_372_036_854_775_807, do: reject("invalid_rooms")

    due =
      Enum.sum(
        Enum.map(amounts, fn amount ->
          if op["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount
        end)
      )

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        rooms: Enum.map(rooms, &Map.take(&1, ["room_id", "nightly_rate_cents"])),
        lodging_total_cents: Enum.sum(amounts),
        deposit_due_cents: due
      })

    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp update(op) do
    group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

    if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
      Repo.rollback(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op["expected_revision"],
        actual_revision: group.revision
      })
    end

    if group.status != "active", do: reject("group_not_active")
    occurred = date!(op["occurred_on"], "invalid_operation")
    {changes, fields} = changes(op, group, occurred)

    updated =
      group
      |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
      |> Repo.update!()

    Map.merge(fields, %{group_id: updated.group_id, revision: updated.revision})
  end

  defp changes(%{"type" => "record_cash_payment"} = op, group, _) do
    require_fields(op, ["amount_cents"])
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp changes(%{"type" => "reschedule_group"} = op, group, occurred) do
    require_fields(op, ["new_arrival_on"])
    arrival = date!(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred) == :gt, do: reject("invalid_stay")
    departure = shifted_departure!(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{new_arrival_on: arrival, new_departure_on: departure}}
  end

  defp changes(%{"type" => "cancel_group"}, group, occurred) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       refunded_cents: refunded,
       retained_cents: retained
     }, %{refunded_cents: refunded, retained_cents: retained}}
  end

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}),
    do: identifier?(id) and is_integer(rate) and rate >= 0

  defp valid_room?(_), do: false

  defp require_fields(op, fields) do
    unless is_map(op) and Enum.all?(fields, &Map.has_key?(op, &1)),
      do: reject("invalid_operation")
  end

  defp date!(value, code) do
    case if(is_binary(value), do: Date.from_iso8601(value), else: :error) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp shifted_departure!(arrival, nights) do
    departure = Date.add(arrival, nights)
    if departure.year > 9999 or departure.year < -9999, do: reject("invalid_stay")
    departure
  rescue
    ArgumentError -> reject("invalid_stay")
  end

  defp reject(code), do: Repo.rollback(%{code: code})
end
