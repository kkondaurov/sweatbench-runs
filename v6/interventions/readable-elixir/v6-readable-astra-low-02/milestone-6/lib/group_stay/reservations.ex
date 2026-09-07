defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes reservation and cash balances.

  Each operation holds SQLite's write reservation from lookup through commit.
  This makes revision comparisons atomic, including across service processes.
  Handled rejections roll back domain effects and retain their durable result.
  """
  alias GroupStay.{Repo, Operations}
  alias GroupStay.Reservations.{Group, CancellationPolicy, HotelCredit, RoomAccounting, Payments}

  @required %{
    "start_finance_reporting" => [],
    "transfer_deposit" => ~w(amount_cents),
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "apply_hotel_credit" => ~w(amount_cents)
  }

  def get_group(id) do
    {:ok, result} = Repo.transaction(fn -> read_group(id) end)
    result
  end

  defp read_group(id) do
    case Repo.get(Group, id) do
      nil -> nil
      group -> Group.to_map(group)
    end
  end

  def guest_credit(id, on \\ Date.utc_today()), do: HotelCredit.balance(id, on)

  def ledger(on \\ Date.utc_today()) do
    # All totals must describe the same snapshot while deposits are being settled.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    Payments.ledger()
    |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
    |> Map.put(:credit_shortfall_cents, HotelCredit.shortfall())
  end

  def submit(operations), do: Enum.map(operations, &apply_operation/1)

  defp apply_operation(operation) do
    Operations.execute(operation, fn ->
      validate_envelope!(operation)
      GroupStay.Finance.capture(operation, fn -> dispatch(operation) end)
    end)
  end

  defp validate_envelope!(op) when is_map(op) do
    required = Map.get(@required, op["type"])

    addresses =
      case op["type"] do
        "start_finance_reporting" ->
          []

        "transfer_deposit" ->
          ~w(source_group_id destination_group_id)

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          ~w(payment_operation_id)

        _ ->
          ~w(group_id)
      end

    unless required && Enum.all?(["operation_id" | addresses], &identifier?(op[&1])) &&
             Map.has_key?(op, "occurred_on") do
      reject("invalid_operation")
    end
  end

  defp validate_envelope!(_), do: reject("invalid_operation")

  defp validate_fields!(op) do
    unless Enum.all?(Map.fetch!(@required, op["type"]), &Map.has_key?(op, &1)) do
      reject("invalid_operation")
    end
  end

  defp dispatch(%{"type" => "start_finance_reporting"} = op) do
    on = date!(op["starts_on"], "invalid_reporting_date")
    date!(op["occurred_on"], "invalid_stay")
    GroupStay.Finance.start(on)
  end

  defp dispatch(%{"type" => "open_group"} = op) do
    validate_fields!(op)
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")

    unless identifier?(op["guest_id"]) && identifier?(op["property_id"]),
      do: reject("invalid_operation")

    booked_on = date!(op["occurred_on"], "invalid_stay")
    arrival_on = date!(op["arrival_on"], "invalid_stay")
    departure_on = date!(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    if nights < 1, do: reject("invalid_stay")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")
    rooms = rooms!(op["rooms"])
    lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    deposit =
      if op["rate_plan"] == "flexible",
        do: Enum.sum(Enum.map(lodging, &div(&1 * 20 + 50, 100))),
        else: Enum.sum(lodging)

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: op["rate_plan"],
        policy_version: CancellationPolicy.version(op["rate_plan"], booked_on),
        rooms: rooms,
        lodging_total_cents: Enum.sum(lodging),
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp dispatch(%{"type" => "transfer_deposit"} = op) do
    source = transfer_group!(op["source_group_id"])
    destination = transfer_group!(op["destination_group_id"])
    check_revision!(source, op, "expected_revision")
    check_revision!(destination, op, "destination_expected_revision")
    validate_fields!(op)
    date!(op["occurred_on"], "invalid_stay")

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination], group.status != "active" do
      Operations.reject(%{code: "group_not_active", group_id: group.group_id})
    end

    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > Group.outstanding(destination), do: reject("transfer_exceeds_outstanding")

    RoomAccounting.transfer(source, destination, amount)
    RoomAccounting.refresh_other_groups([source.group_id, destination.group_id], nil)

    %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: Group.outstanding(source) + amount,
      destination_outstanding_deposit_cents: Group.outstanding(destination) - amount,
      source_revision: source.revision + 1,
      destination_revision: destination.revision + 1
    }
  end

  defp dispatch(op) do
    group_id =
      case op["type"] do
        "reduce_cash_payment" ->
          Payments.target!(op["payment_operation_id"], "payment_not_reducible").result["group_id"]

        "charge_back_payment" ->
          Payments.target!(op["payment_operation_id"], "payment_not_chargeable").result[
            "group_id"
          ]

        _ ->
          op["group_id"]
      end

    group = Repo.get(Group, group_id) || reject("group_not_found")

    check_revision!(group, op, "expected_revision")

    validate_fields!(op)

    if group.status != "active" and
         op["type"] not in ["reduce_cash_payment", "charge_back_payment"],
       do: reject("group_not_active")

    occurred_on = date!(op["occurred_on"], "invalid_stay")
    {changes, result} = change(group, op, occurred_on)
    revision = group.revision + 1
    group |> Ecto.Changeset.change(Map.put(changes, :revision, revision)) |> Repo.update!()
    Map.merge(result, %{group_id: group.group_id, revision: revision})
  end

  defp transfer_group!(id) do
    Repo.get(Group, id) || Operations.reject(%{code: "group_not_found", group_id: id})
  end

  defp check_revision!(group, op, key) do
    if Map.has_key?(op, key) && op[key] !== group.revision do
      Operations.reject(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op[key],
        actual_revision: group.revision
      })
    end
  end

  defp change(group, %{"type" => "record_cash_payment", "amount_cents" => amount} = op, _) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")

    RoomAccounting.fund(group, amount, :cash, op["operation_id"])

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "apply_hotel_credit", "amount_cents" => amount} = op, on) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > Group.outstanding(group), do: reject("payment_exceeds_outstanding")
    HotelCredit.apply(group, amount, on, op["operation_id"])

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    arrival = date!(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred_on) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp change(group, %{"type" => "reduce_cash_payment"} = op, _) do
    Payments.reduce(group, op["payment_operation_id"], op["amount_cents"])
  end

  defp change(group, %{"type" => "charge_back_payment"} = op, on) do
    Payments.charge_back(group, op["payment_operation_id"], on)
  end

  defp change(group, %{"type" => type} = op, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    active_ids =
      RoomAccounting.rooms(group)
      |> Enum.filter(&(&1["status"] == "active"))
      |> Enum.map(& &1["room_id"])

    requested = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    unless is_list(requested) and requested != [] and
             length(Enum.uniq(requested)) == length(requested) and
             Enum.all?(requested, &(&1 in active_ids)),
           do: reject("invalid_rooms")

    ids = Enum.filter(active_ids, &(&1 in requested))
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    refundable = CancellationPolicy.refundable?(group, occurred_on)
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    cash_rows = RoomAccounting.held_cash(group.group_id) |> Enum.filter(&(&1.room_id in ids))
    cash = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    converted = if method == "hotel_credit", do: cash, else: 0
    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    issued =
      if converted > 0,
        do: HotelCredit.issue(group, op["operation_id"], occurred_on, cash_rows),
        else: 0

    disposition =
      cond do
        converted > 0 -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    Payments.settle(cash_rows, disposition)
    HotelCredit.settle(group, ids, refundable, occurred_on)

    changes =
      Map.merge(RoomAccounting.cancel(group, ids), %{
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        converted_cents: group.converted_cents + converted
      })

    result = %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}

    result =
      if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result

    {changes, result}
  end

  defp rooms!(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) && is_integer(rate) && rate >= 0

        _ ->
          false
      end)

    unless valid, do: reject("invalid_rooms")
    ids = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(ids)) == length(ids), do: reject("invalid_rooms")
    Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
  end

  defp rooms!(_), do: reject("invalid_rooms")

  defp date!(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp date!(_, code), do: reject(code)
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0
  defp reject(code), do: Operations.reject(%{code: code})
end
