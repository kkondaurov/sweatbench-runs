defmodule GroupStay.Reservations do
  @moduledoc "Reservation operations and cash accounting, committed one operation at a time."
  import Ecto.Query
  alias GroupStay.{CreditLot, Group, Repo}

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision policy_version cash_paid_cents credit_paid_cents rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a
  @required %{
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "cancel_group" => ~w(group_id),
    "apply_hotel_credit" => ~w(group_id amount_cents)
  }

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(id, on \\ Date.utc_today()) do
    lots = available_lots(id, on)

    %{
      guest_id: id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    groups = Repo.all(Group)
    active = Enum.filter(groups, &(&1.status == "active"))
    available = Repo.all(from l in CreditLot, where: l.expires_on >= ^on)

    %{
      cash_held_cents: Enum.sum(Enum.map(active, & &1.cash_paid_cents)),
      cash_refunded_cents: Enum.sum(Enum.map(groups, & &1.refunded_cents)),
      cash_retained_cents: Enum.sum(Enum.map(groups, & &1.retained_cents)),
      cash_converted_to_credit_cents: Enum.sum(Enum.map(groups, & &1.converted_cents)),
      credit_liability_cents:
        Enum.sum(Enum.map(available, & &1.remaining_cents)) +
          Enum.sum(Enum.map(active, & &1.credit_paid_cents))
    }
  end

  defp available_lots(id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
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
        policy_version: policy(op["rate_plan"], date(op["occurred_on"])),
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

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       cash_paid_cents: group.cash_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "reschedule_group"} = op) do
    arrival = date(op["new_arrival_on"])

    unless arrival && Date.compare(arrival, date(op["occurred_on"])) == :gt,
      do: reject("invalid_stay")

    nights = Date.diff(group.departure_on, group.arrival_on)
    if Date.diff(~D[9999-12-31], arrival) < nights, do: reject("invalid_stay")
    departure = Date.add(arrival, nights)

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp change(group, %{"type" => "apply_hotel_credit", "amount_cents" => amount} = op) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    lots = available_lots(group.guest_id, date(op["occurred_on"]))
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    {0, allocations} =
      Enum.reduce(lots, {amount, []}, fn lot, {needed, allocations} ->
        used = min(needed, lot.remaining_cents)

        if used > 0 do
          Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))
          {needed - used, allocations ++ [%{"lot_id" => lot.id, "amount_cents" => used}]}
        else
          {needed, allocations}
        end
      end)

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount,
       credit_allocations: group.credit_allocations ++ allocations
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "cancel_group"} = op) do
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    on = date(op["occurred_on"])
    cutoff = refundable_until(group)
    refundable = cutoff != nil && Date.compare(on, cutoff) != :gt
    if method == "hotel_credit" && !refundable, do: reject("refund_method_not_available")

    converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0
    issued = converted + div(converted * 10 + 50, 100)
    refunded = if refundable && method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    if issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(on, 365)
      })
    end

    if refundable do
      for allocation <- group.credit_allocations do
        lot = Repo.get!(CreditLot, allocation["lot_id"])
        # Restored funds retain their expiry; date-filtered reads omit expired funds.
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + allocation["amount_cents"]
          )
        )
      end
    end

    {%{
       status: "cancelled",
       deposit_due_cents: 0,
       deposit_paid_cents: 0,
       cash_paid_cents: 0,
       credit_paid_cents: 0,
       credit_allocations: [],
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
