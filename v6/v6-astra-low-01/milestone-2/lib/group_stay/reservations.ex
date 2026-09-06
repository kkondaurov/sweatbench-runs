defmodule GroupStay.Reservations do
  alias GroupStay.{CreditLot, Group, Repo}
  import Ecto.Query

  def batch(operations), do: Enum.map(operations, &process/1)

  def get(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.from_struct()
        |> Map.drop([
          :__meta__,
          :refunded_cents,
          :retained_cents,
          :converted_cents,
          :credit_allocations
        ])
        |> Map.put(:refundable_until, refundable_until(group))
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def credit(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  def ledger(on \\ Date.utc_today()) do
    # Both components must share a snapshot when a concurrent operation redeems credit.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.converted_cents), 0),
            credit_liability_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.credit_paid_cents
                  )
                ),
                0
              )
          }
      )

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    Map.update!(totals, :credit_liability_cents, &(&1 + available))
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
                   "apply_hotel_credit",
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
        policy_version: policy(op["rate_plan"], booked),
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

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       cash_paid_cents: group.cash_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp changes(%{"type" => "reschedule_group"} = op, group, occurred) do
    require_fields(op, ["new_arrival_on"])
    arrival = date!(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred) == :gt, do: reject("invalid_stay")
    departure = shifted_departure!(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp changes(%{"type" => "apply_hotel_credit"} = op, group, occurred) do
    require_fields(op, ["amount_cents"])
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    lots = Repo.all(available_lots(group.guest_id, occurred))
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    {0, allocations} =
      Enum.reduce(lots, {amount, group.credit_allocations}, fn lot, {needed, allocations} ->
        used = min(needed, lot.remaining_cents)

        if used == 0 do
          {needed, allocations}
        else
          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
          |> Repo.update!()

          {needed - used, allocations ++ [%{"lot_id" => lot.id, "amount_cents" => used}]}
        end
      end)

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount,
       credit_allocations: allocations
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp changes(%{"type" => "cancel_group"} = op, group, occurred) do
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    deadline = refundable_until(group)
    refundable = deadline != nil and Date.compare(occurred, deadline) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")
    converted = if refundable and method == "hotel_credit", do: group.cash_paid_cents, else: 0
    issued = converted + div(converted * 10 + 50, 100)

    if issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred, 365)
      })
    end

    if refundable do
      Enum.each(group.credit_allocations, fn allocation ->
        lot = Repo.get!(CreditLot, allocation["lot_id"])

        if Date.compare(lot.expires_on, occurred) != :lt do
          lot
          |> Ecto.Changeset.change(
            remaining_cents: lot.remaining_cents + allocation["amount_cents"]
          )
          |> Repo.update!()
        end
      end)
    end

    refunded = if refundable and method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       refunded_cents: refunded,
       retained_cents: retained,
       converted_cents: converted
     }, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
  end

  defp policy("advance_purchase", _), do: "advance-nonrefundable"

  defp policy("flexible", booked) do
    if Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
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
