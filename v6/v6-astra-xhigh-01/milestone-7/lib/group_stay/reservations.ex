defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations and maintains group deposits and cancellation settlements.

  Each operation has its own transaction. SQLite's immediate transaction mode acquires
  the write lock before reading a revision or balance, including across server processes.
  """

  import Ecto.Query

  alias GroupStay.{FinanceReporting, Operations, Repo}
  alias GroupStay.Reservations.{Group, HotelCredit, Payment, Payments, Room, RoomAccounting}
  import GroupStay.Operations.Rejection, only: [reject: 1, reject: 2]

  @payment_operations ~w(reduce_cash_payment charge_back_payment)
  @finance_operations ~w(start_finance_reporting close_finance_period)
  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms transfer_deposit) ++
                     @payment_operations ++ @finance_operations
  @max_cents 9_223_372_036_854_775_807

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) do
    {:ok, data} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil -> nil
          group -> group |> Repo.preload(:rooms) |> group_data()
        end
      end)

    data
  end

  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.guest_credit(guest_id, on)

  def report_date(nil), do: {:ok, Date.utc_today()}

  def report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = parsed} when year >= 0 and year <= 9999 -> {:ok, parsed}
      _ -> {:error, :invalid_date}
    end
  end

  def report_date(_value), do: {:error, :invalid_date}

  def ledger(on \\ Date.utc_today()) do
    # Sum exact integers in a read snapshot, without SQLite SUM's 64-bit overflow
    # or loading every reservation into memory.
    {:ok, totals} =
      Repo.transaction(fn ->
        query =
          from g in Group,
            select: %{
              cash_held_cents: g.deposit_paid_cents - g.credit_paid_cents,
              cash_refunded_cents: g.cash_refunded_cents,
              cash_retained_cents: g.cash_retained_cents,
              cash_converted_to_credit_cents: g.cash_converted_to_credit_cents,
              credit_liability_cents: g.credit_paid_cents
            }

        totals =
          query
          |> Repo.stream()
          |> Enum.reduce(
            %{
              cash_held_cents: 0,
              cash_refunded_cents: 0,
              cash_retained_cents: 0,
              cash_converted_to_credit_cents: 0,
              credit_liability_cents: 0
            },
            fn row, totals ->
              Map.merge(totals, row, fn _key, total, amount -> total + amount end)
            end
          )

        available =
          on
          |> HotelCredit.available_query()
          |> select([lot], lot.remaining_cents)
          |> Repo.stream()
          |> Enum.reduce(0, &+/2)

        {reduced, charged_back} =
          Repo.stream(from p in Payment, select: {p.reduced_cents, p.charged_back_cents})
          |> Enum.reduce({0, 0}, fn {r, c}, {rs, cs} -> {rs + r, cs + c} end)

        totals
        |> Map.update!(:credit_liability_cents, &(&1 + available))
        |> Map.put(:cash_reduced_cents, reduced)
        |> Map.put(:cash_charged_back_cents, charged_back)
        |> Map.put(:credit_shortfall_cents, HotelCredit.shortfall())
      end)

    totals
  end

  defp apply_operation(operation) do
    operation
    |> Operations.run(fn -> dispatch(operation) end)
    # Result field names are defined by this service; nested partner values keep
    # their JSON keys and are never converted to atoms.
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp dispatch(operation) when is_map(operation) do
    type = operation["type"]

    target_key =
      cond do
        type in @payment_operations -> "payment_operation_id"
        type == "transfer_deposit" -> "source_group_id"
        true -> "group_id"
      end

    unless type in @operation_types and identifier?(operation["operation_id"]) and
             (type in @finance_operations or identifier?(operation[target_key])),
           do: reject("invalid_operation")

    cond do
      type == "start_finance_reporting" ->
        %{starts_on: FinanceReporting.start(operation)}

      type == "close_finance_period" ->
        %{period_end_on: FinanceReporting.close(operation)}

      type == "open_group" ->
        open_group(operation)

      type in @payment_operations ->
        update_payment(operation)

      type == "transfer_deposit" ->
        transfer_deposit(operation)

      true ->
        group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
        check_revision(group, operation)
        occurred_on = operation_date(operation)
        required_fields(operation, required_fields_for(type))
        if group.status != "active" and type != "cancel_rooms", do: reject("group_not_active")
        posting = FinanceReporting.posting(operation["operation_id"], occurred_on)
        {changes, result} = update_group(group, operation, occurred_on, posting)
        finish_update(group, changes, result)
    end
  end

  defp dispatch(_operation), do: reject("invalid_operation")

  defp finish_update(group, changes, result) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()

    Map.merge(result, %{group_id: group.group_id, revision: group.revision + 1})
  end

  defp update_payment(operation) do
    type = operation["type"]

    payment =
      case Payments.fetch(operation["payment_operation_id"]) do
        {:ok, payment} ->
          payment

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

    group = Repo.get(Group, payment.original_group_id) || reject("group_not_found")
    check_revision(group, operation)
    occurred_on = operation_date(operation)
    posting = FinanceReporting.posting(operation["operation_id"], occurred_on)

    {changes, result} =
      if type == "reduce_cash_payment" do
        required_fields(operation, ["amount_cents"])
        {amount, changes} = Payments.reduce(payment, operation["amount_cents"], posting)
        {changes, %{amount_cents: amount}}
      else
        {charged_back, changes} = Payments.charge_back(payment, posting)
        {changes, %{charged_back_cents: charged_back}}
      end

    # A payment always addresses its original group, even after all of its cash
    # has moved away. Every other affected group advances exactly once as well.
    changes
    |> Map.put_new(group.group_id, %{})
    |> Enum.each(fn {group_id, deltas} ->
      affected = Repo.get!(Group, group_id)

      fields =
        Map.new(deltas, fn {field, delta} -> {field, Map.fetch!(affected, field) + delta} end)

      finish_update(affected, fields, %{})
    end)

    group = Repo.get!(Group, group.group_id)

    Map.merge(result, %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      revision: group.revision,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    })
  end

  defp transfer_deposit(operation) do
    unless identifier?(operation["destination_group_id"]), do: reject("invalid_operation")

    source = transfer_group(operation["source_group_id"])
    destination = transfer_group(operation["destination_group_id"])
    check_revision(source, operation)
    check_revision(destination, operation, "destination_expected_revision")
    occurred_on = operation_date(operation)
    required_fields(operation, ["amount_cents"])

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination],
        group.status != "active",
        do: reject("group_not_active", %{group_id: group.group_id})

    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    outstanding = destination.deposit_due_cents - destination.deposit_paid_cents
    if amount > outstanding, do: reject("transfer_exceeds_outstanding")

    credit = RoomAccounting.transfer(source.group_id, destination.group_id, amount)
    posting = FinanceReporting.posting(operation["operation_id"], occurred_on)
    FinanceReporting.cash(posting, source, :transferred_out_cents, amount - credit)
    FinanceReporting.cash(posting, destination, :transferred_in_cents, amount - credit)

    finish_update(
      source,
      %{
        deposit_paid_cents: source.deposit_paid_cents - amount,
        credit_paid_cents: source.credit_paid_cents - credit
      },
      %{}
    )

    finish_update(
      destination,
      %{
        deposit_paid_cents: destination.deposit_paid_cents + amount,
        credit_paid_cents: destination.credit_paid_cents + credit
      },
      %{}
    )

    %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents:
        source.deposit_due_cents - source.deposit_paid_cents + amount,
      destination_outstanding_deposit_cents: outstanding - amount,
      source_revision: source.revision + 1,
      destination_revision: destination.revision + 1
    }
  end

  defp transfer_group(group_id),
    do: Repo.get(Group, group_id) || reject("group_not_found", %{group_id: group_id})

  defp check_revision(group, operation, key \\ "expected_revision") do
    if Map.has_key?(operation, key) and
         operation[key] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation[key],
        actual_revision: group.revision
      })
    end
  end

  defp open_group(operation) do
    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    booked_on = operation_date(operation)
    required_fields(operation, ~w(guest_id property_id arrival_on departure_on rate_plan rooms))

    unless identifier?(operation["guest_id"]) and identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    arrival_on = date(operation["arrival_on"], "invalid_stay")
    departure_on = date(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    if nights < 1, do: reject("invalid_stay")

    rate_plan = operation["rate_plan"]
    unless rate_plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")

    rooms = validate_rooms(operation["rooms"])
    lodging_total = Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights)))
    if lodging_total > @max_cents, do: reject("invalid_rooms")

    deposit_due =
      Enum.sum(
        Enum.map(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights
          if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)
      )

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      })

    Repo.insert_all(
      Room,
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group.group_id,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          position: position,
          lodging_total_cents: room["nightly_rate_cents"] * nights,
          deposit_due_cents: room_deposit(room["nightly_rate_cents"] * nights, rate_plan)
        }
      end)
    )

    %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: 1}
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = operation, _occurred_on, posting) do
    {amount, outstanding} = payment_amount(group, operation)

    Payments.record(group.group_id, operation["operation_id"], amount)
    FinanceReporting.cash(posting, group, :received_cents, amount)

    {%{deposit_paid_cents: group.deposit_paid_cents + amount},
     %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}}
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on, posting) do
    {amount, outstanding} = payment_amount(group, operation)
    HotelCredit.apply_to_group(group, amount, occurred_on, posting)

    {%{
       deposit_paid_cents: group.deposit_paid_cents + amount,
       credit_paid_cents: group.credit_paid_cents + amount
     }, %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}}
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, occurred_on, _posting) do
    arrival_on = date(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")

    departure_on = Date.add(arrival_on, Date.diff(group.departure_on, group.arrival_on))

    # Keep shifted dates representable in the API's four-digit ISO calendar format.
    if departure_on.year > 9999, do: reject("invalid_stay")

    {%{arrival_on: arrival_on, departure_on: departure_on},
     %{
       new_arrival_on: arrival_on,
       new_departure_on: departure_on,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival_on})
     }}
  end

  defp update_group(group, %{"type" => type} = operation, occurred_on, posting)
       when type in ["cancel_group", "cancel_rooms"] do
    active = RoomAccounting.active_rooms(group.group_id)

    rooms =
      if type == "cancel_rooms" do
        ids = operation["room_ids"]

        unless is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
                 Enum.all?(ids, fn id -> Enum.any?(active, &(&1.room_id === id)) end),
               do: reject("invalid_rooms")

        Enum.filter(active, &(&1.room_id in ids))
      else
        active
      end

    method = Map.get(operation, "refund_method", "cash")
    unless method in ~w(cash hotel_credit), do: reject("invalid_operation")
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    settlement =
      RoomAccounting.settle(
        group,
        rooms,
        refundable,
        method,
        operation["operation_id"],
        occurred_on,
        posting
      )

    changes = %{
      status: if(length(rooms) == length(active), do: "cancelled", else: "active"),
      lodging_total_cents:
        group.lodging_total_cents - Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
      deposit_due_cents:
        group.deposit_due_cents - Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      deposit_paid_cents:
        group.deposit_paid_cents -
          Enum.sum(Enum.map(rooms, &(&1.cash_paid_cents + &1.credit_paid_cents))),
      credit_paid_cents:
        group.credit_paid_cents - Enum.sum(Enum.map(rooms, & &1.credit_paid_cents)),
      cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
      cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_to_credit_cents
    }

    result = Map.take(settlement, [:refunded_cents, :retained_cents, :credit_issued_cents])

    result =
      if type == "cancel_rooms",
        do: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
        else: result

    {changes, result}
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp payment_amount(group, operation) do
    amount = operation["amount_cents"]
    unless cents?(amount) and amount > 0, do: reject("invalid_amount")

    outstanding = group.deposit_due_cents - group.deposit_paid_cents
    if amount > outstanding, do: reject("payment_exceeds_outstanding")
    {amount, outstanding}
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          identifier?(room_id) and cents?(rate)

        _ ->
          false
      end)

    unless valid?, do: reject("invalid_rooms")

    room_ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(room_ids)) != length(room_ids), do: reject("invalid_rooms")
    rooms
  end

  defp validate_rooms(_rooms), do: reject("invalid_rooms")

  defp required_fields_for("record_cash_payment"), do: ["amount_cents"]
  defp required_fields_for("apply_hotel_credit"), do: ["amount_cents"]
  defp required_fields_for("reschedule_group"), do: ["new_arrival_on"]
  defp required_fields_for("cancel_group"), do: []
  defp required_fields_for("cancel_rooms"), do: ["room_ids"]

  defp required_fields(operation, fields) do
    unless Enum.all?(fields, &Map.has_key?(operation, &1)), do: reject("invalid_operation")
  end

  defp operation_date(operation), do: date(operation["occurred_on"], "invalid_operation")

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = parsed} when year >= 0 and year <= 9999 -> parsed
      _ -> reject(code)
    end
  end

  defp date(_value, code), do: reject(code)

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp cents?(value), do: is_integer(value) and value >= 0 and value <= @max_cents

  defp group_data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, group.deposit_paid_cents - group.credit_paid_cents)
    |> Map.put(:refundable_until, refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, group.deposit_due_cents - group.deposit_paid_cents)
    |> Map.put(
      :rooms,
      Enum.map(
        group.rooms,
        &Map.take(&1, [
          :room_id,
          :nightly_rate_cents,
          :status,
          :lodging_total_cents,
          :deposit_due_cents,
          :cash_paid_cents,
          :credit_paid_cents
        ])
      )
    )
  end
end
