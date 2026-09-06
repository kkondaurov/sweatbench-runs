defmodule GroupStay.Reservations do
  @moduledoc "Reservation operations and cash accounting, committed one operation at a time."
  import Ecto.Query
  alias GroupStay.{Group, Repo}

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a
  @required %{
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "cancel_group" => ~w(group_id)
  }

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group |> Map.take(@fields) |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def ledger do
    {held, refunded, retained} =
      Repo.one(
        from g in Group,
          select:
            {sum(
               fragment(
                 "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                 g.status,
                 g.deposit_paid_cents
               )
             ), sum(g.refunded_cents), sum(g.retained_cents)}
      )

    %{
      cash_held_cents: held || 0,
      cash_refunded_cents: refunded || 0,
      cash_retained_cents: retained || 0
    }
  end

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  defp apply_operation(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil
    # Acquire SQLite's write reservation before reading a revision. This also protects
    # unconditional payments from observing the same outstanding balance concurrently.
    case Repo.transaction(
           fn ->
             validate_operation!(op)
             result = dispatch(op)
             Map.merge(result, %{operation_id: id, status: "applied"})
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, error} -> Map.merge(error, %{operation_id: id, status: "rejected"})
    end
  end

  defp validate_operation!(op) when is_map(op) do
    required = @required[op["type"]]

    unless required && Enum.all?(required ++ ~w(operation_id occurred_on), &Map.has_key?(op, &1)),
      do: reject("invalid_operation")

    unless Enum.all?(
             Enum.filter(
               required ++ ["operation_id"],
               &(&1 in ~w(group_id guest_id property_id operation_id))
             ),
             &identifier?(op[&1])
           ),
           do: reject("invalid_operation")

    unless date(op["occurred_on"]), do: reject("invalid_operation")
  end

  defp validate_operation!(_), do: reject("invalid_operation")

  defp dispatch(%{"type" => "open_group"} = op) do
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    arrival = date(op["arrival_on"])
    departure = date(op["departure_on"])

    unless arrival && departure && Date.compare(departure, arrival) == :gt,
      do: reject("invalid_stay")

    rooms = op["rooms"]

    unless is_list(rooms) && rooms != [] && Enum.all?(rooms, &valid_room?/1) &&
             length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms),
           do: reject("invalid_rooms")

    unless op["rate_plan"] in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    nights = Date.diff(departure, arrival)
    amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
    if Enum.sum(amounts) > 9_223_372_036_854_775_807, do: reject("invalid_rooms")

    due =
      if op["rate_plan"] == "flexible",
        do: Enum.sum(Enum.map(amounts, &div(&1 * 20 + 50, 100))),
        else: Enum.sum(amounts)

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: date(op["occurred_on"]),
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        rooms: Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        lodging_total_cents: Enum.sum(amounts),
        deposit_due_cents: due
      })

    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp dispatch(op) do
    group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

    if Map.has_key?(op, "expected_revision") && op["expected_revision"] !== group.revision do
      Repo.rollback(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op["expected_revision"],
        actual_revision: group.revision
      })
    end

    unless group.status == "active", do: reject("group_not_active")
    {changes, result} = change(group, op)
    Repo.update!(Ecto.Changeset.change(group, Map.put(changes, :revision, group.revision + 1)))
    Map.merge(result, %{group_id: group.group_id, revision: group.revision + 1})
  end

  defp change(group, %{"type" => "record_cash_payment", "amount_cents" => amount}) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "reschedule_group"} = op) do
    arrival = date(op["new_arrival_on"])

    unless arrival && Date.compare(arrival, date(op["occurred_on"])) == :gt,
      do: reject("invalid_stay")

    nights = Date.diff(group.departure_on, group.arrival_on)
    if Date.diff(~D[9999-12-31], arrival) < nights, do: reject("invalid_stay")
    departure = Date.add(arrival, nights)

    {%{arrival_on: arrival, departure_on: departure},
     %{new_arrival_on: arrival, new_departure_on: departure}}
  end

  defp change(group, %{"type" => "cancel_group"} = op) do
    refundable =
      group.rate_plan == "flexible" && Date.diff(group.arrival_on, date(op["occurred_on"])) >= 14

    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       deposit_paid_cents: 0,
       refunded_cents: refunded,
       retained_cents: retained
     }, %{refunded_cents: refunded, retained_cents: retained}}
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}),
    do: identifier?(id) && is_integer(rate) && rate >= 0

  defp valid_room?(_), do: false

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp reject(code), do: Repo.rollback(%{code: code})
end
