defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order, with one atomic transaction per operation.
  SQLite immediate transactions acquire the write reservation before reading,
  keeping revision comparisons and settlement updates atomic across callers.
  """
  alias GroupStay.{Accounting, Credit, Repo}
  alias GroupStay.Reservations.CancellationPolicy
  alias GroupStay.Reservations.Group

  @payment_corrections ~w(reduce_cash_payment charge_back_payment)

  @required %{
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "apply_hotel_credit" => ~w(group_id amount_cents),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "cancel_group" => ~w(group_id),
    "cancel_rooms" => ~w(group_id room_ids),
    "reduce_cash_payment" => ~w(payment_operation_id amount_cents),
    "charge_back_payment" => ~w(payment_operation_id)
  }

  def submit(operations), do: Enum.map(operations, &apply_operation/1)
  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()) do
    # All components must describe the same snapshot during concurrent settlement.
    {:ok, totals} =
      Repo.transaction(fn ->
        Accounting.ledger()
        |> Map.put(:credit_liability_cents, Credit.liability(on))
        |> Map.put(:credit_shortfall_cents, Credit.shortfall())
      end)

    totals
  end

  defp apply_operation(operation) do
    GroupStay.Operations.execute(operation, fn -> dispatch(operation) end)
  end

  defp dispatch(op) when is_map(op) do
    required = @required[op["type"]]

    address_key =
      if op["type"] in @payment_corrections, do: "payment_operation_id", else: "group_id"

    unless required && Enum.all?(required, &Map.has_key?(op, &1)) &&
             identifier?(op["operation_id"]) && identifier?(op[address_key]),
           do: reject("invalid_operation")

    occurred_on = date(op["occurred_on"])
    unless occurred_on, do: reject("invalid_operation")

    if op["type"] == "open_group" do
      open_group(op, occurred_on)
    else
      group_id = addressed_group(op)
      group = Repo.get(Group, group_id) || reject("group_not_found")

      if Map.has_key?(op, "expected_revision") && op["expected_revision"] !== group.revision do
        GroupStay.Operations.reject(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        })
      end

      unless group.status == "active" or
               op["type"] in ["cancel_rooms" | @payment_corrections],
             do: reject("group_not_active")

      {changes, result} = change_group(group, op, occurred_on)

      updated =
        group
        |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
        |> Repo.update!()

      Map.merge(result, %{group_id: updated.group_id, revision: updated.revision})
    end
  end

  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(op, booked_on) do
    unless identifier?(op["guest_id"]) && identifier?(op["property_id"]),
      do: reject("invalid_operation")

    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    arrival = date(op["arrival_on"])
    departure = date(op["departure_on"])

    unless arrival && departure && Date.compare(departure, arrival) == :gt,
      do: reject("invalid_stay")

    rooms = op["rooms"]
    unless valid_rooms?(rooms), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")

    nights = Date.diff(departure, arrival)

    rooms =
      Accounting.rooms(
        Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        nights,
        op["rate_plan"]
      )

    deposit = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        policy_version: CancellationPolicy.version(op["rate_plan"], booked_on),
        rooms: rooms,
        lodging_total_cents: Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"])),
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp change_group(group, %{"type" => type} = op, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    amount = op["amount_cents"]
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")

    if type == "apply_hotel_credit" do
      Credit.apply_to_group(group, amount, occurred_on)
    else
      Accounting.fund_cash(group, op["operation_id"], amount)
    end

    {Accounting.changes(group),
     %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change_group(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    arrival = date(op["new_arrival_on"])
    unless arrival && Date.compare(arrival, occurred_on) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp change_group(group, %{"type" => type} = op, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    active_ids =
      group.rooms |> Enum.filter(&(&1["status"] == "active")) |> Enum.map(& &1["room_id"])

    requested = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    unless is_list(requested) and requested != [] and
             length(Enum.uniq(requested)) == length(requested) and
             Enum.all?(requested, &(&1 in active_ids)),
           do: reject("invalid_rooms")

    ids = Enum.filter(active_ids, &(&1 in requested))
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    refundable = CancellationPolicy.refundable?(group, occurred_on)
    if method == "hotel_credit" && !refundable, do: reject("refund_method_not_available")

    {changes, result} =
      Accounting.settle(group, ids, refundable, method, op["operation_id"], occurred_on)

    result =
      if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result

    {changes, result}
  end

  defp change_group(group, %{"type" => "reduce_cash_payment"} = op, _) do
    Accounting.reduce(group, op["payment_operation_id"], op["amount_cents"])
  end

  defp change_group(group, %{"type" => "charge_back_payment"} = op, _) do
    Accounting.charge_back(group, op["payment_operation_id"])
  end

  defp addressed_group(%{"type" => type} = op)
       when type in @payment_corrections do
    case Accounting.fetch_payment_record(op["payment_operation_id"]) do
      {:ok, record} ->
        record.result["group_id"]

      {:error, "operation_not_found"} ->
        reject("operation_not_found")

      {:error, _} ->
        reject(
          if(type == "reduce_cash_payment",
            do: "payment_not_reducible",
            else: "payment_not_chargeable"
          )
        )
    end
  end

  defp addressed_group(op), do: op["group_id"]

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => id, "nightly_rate_cents" => rate} ->
        identifier?(id) && is_integer(rate) && rate >= 0

      _ ->
        false
    end) && length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp reject(code), do: GroupStay.Operations.reject(%{code: code})
end
