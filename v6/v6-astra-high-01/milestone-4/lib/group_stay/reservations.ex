defmodule GroupStay.Reservations do
  @moduledoc "Processes ordered partner operations and keeps reservation deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, HotelCredit, Operations, Payments, Repo, RoomAccounting}

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms reduce_cash_payment charge_back_payment)
  @max_cents 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on rate_plan policy_version status rooms lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents credit_paid_cents)a

  def submit(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.available(guest_id, on)

  def ledger(on \\ Date.utc_today()) do
    # Read cash, redeemed credit, and available lots from one database snapshot.
    {:ok, totals} =
      Repo.transaction(fn ->
        initial = %{
          cash_held_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          credit_shortfall_cents: HotelCredit.shortfall(),
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          credit_liability_cents: HotelCredit.available_liability(on)
        }

        Repo.all(
          from g in Group,
            select: %{
              cash_held_cents: g.cash_paid_cents,
              cash_reduced_cents: g.cash_reduced_cents,
              cash_charged_back_cents: g.cash_charged_back_cents,
              cash_refunded_cents: g.cash_refunded_cents,
              cash_retained_cents: g.cash_retained_cents,
              cash_converted_to_credit_cents: g.cash_converted_to_credit_cents,
              credit_liability_cents: g.credit_paid_cents
            }
        )
        |> Enum.reduce(initial, fn amounts, totals ->
          Map.merge(totals, amounts, fn _key, total, amount -> total + amount end)
        end)
      end)

    totals
  end

  defp process(operation) do
    # SQLite has one writer. Queue local writes before taking a connection so
    # contending transactions cannot exhaust the pool or block its native workers.
    # IMMEDIATE also protects revisions and balances from other service processes.
    # Each operation commits independently, including within a partner batch.
    lock = {{__MODULE__, Repo.get_dynamic_repo()}, self()}

    {:ok, result} =
      :global.trans(
        lock,
        fn ->
          Repo.transaction(
            fn -> Operations.process(operation, fn -> apply_operation(operation) end) end,
            mode: :immediate
          )
        end,
        [node()]
      )

    result
  end

  defp apply_operation(operation) when is_map(operation) do
    unless identifier?(operation["operation_id"]) and operation["type"] in @types,
      do: reject("invalid_operation")

    cond do
      operation["type"] in ~w(reduce_cash_payment charge_back_payment) ->
        apply_to_payment(operation)

      not identifier?(operation["group_id"]) ->
        reject("invalid_operation")

      operation["type"] == "open_group" ->
        open_group(operation, operation_date(operation))

      true ->
        group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
        check_revision(group, operation)
        if group.status != "active", do: reject("group_not_active")
        apply_to_group(group, operation, operation_date(operation))
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp open_group(operation, booked_on) do
    require_fields(operation, ~w(guest_id property_id arrival_on departure_on rate_plan rooms))

    unless identifier?(operation["guest_id"]) and identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    arrival = parse_date(operation["arrival_on"], "invalid_stay")
    departure = parse_date(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    if nights < 1, do: reject("invalid_stay")

    plan = operation["rate_plan"]
    unless plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    rooms = operation["rooms"] |> validate_rooms() |> RoomAccounting.price_rooms(nights, plan)
    lodging = Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"]))
    deposit = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

    if lodging > @max_cents, do: reject("invalid_rooms")

    group =
      Repo.insert!(%Group{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: plan,
        policy_version: policy_version(plan, booked_on),
        rooms: rooms,
        lodging_total_cents: lodging,
        deposit_due_cents: deposit
      })

    %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}
  end

  defp apply_to_group(group, %{"type" => "record_cash_payment"} = operation, _date) do
    amount = payment_amount(group, operation)

    RoomAccounting.allocate(group, "cash", amount,
      payment_operation_id: operation["operation_id"]
    )

    group = update(group, RoomAccounting.totals(group))

    payment_result(group, amount)
  end

  defp apply_to_group(group, %{"type" => "apply_hotel_credit"} = operation, date) do
    amount = payment_amount(group, operation)
    HotelCredit.apply(group, amount, date)

    group = update(group, RoomAccounting.totals(group))

    payment_result(group, amount)
  end

  defp apply_to_group(group, %{"type" => "reschedule_group"} = operation, date) do
    require_fields(operation, ~w(new_arrival_on))
    arrival = parse_date(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, date) == :gt, do: reject("invalid_stay")
    departure = shift_departure(arrival, Date.diff(group.departure_on, group.arrival_on))
    group = update(group, %{arrival_on: arrival, departure_on: departure})

    %{
      group_id: group.group_id,
      new_arrival_on: arrival,
      new_departure_on: departure,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      revision: group.revision
    }
  end

  defp apply_to_group(group, %{"type" => type} = operation, date)
       when type in ~w(cancel_group cancel_rooms) do
    active_ids = for room <- group.rooms, room["status"] == "active", do: room["room_id"]
    if type == "cancel_rooms", do: require_fields(operation, ~w(room_ids))
    ids = if type == "cancel_group", do: active_ids, else: operation["room_ids"]

    unless is_list(ids) and ids != [] and Enum.uniq(ids) == ids and
             Enum.all?(ids, &(&1 in active_ids)),
           do: reject("invalid_rooms")

    ids = Enum.filter(active_ids, &(&1 in ids))

    method = Map.get(operation, "refund_method", "cash")
    unless method in ~w(cash hotel_credit), do: reject("invalid_operation")
    deadline = refundable_until(group)
    refundable = deadline != nil and Date.compare(date, deadline) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    selected = Enum.filter(RoomAccounting.held(group.group_id), &(&1.room_id in ids))
    {cash, credit} = Enum.split_with(selected, &(&1.kind == "cash"))
    amount = RoomAccounting.sum(cash)
    converted = if method == "hotel_credit", do: amount, else: 0
    refunded = if refundable and method == "cash", do: amount, else: 0
    retained = if refundable, do: 0, else: amount

    {issued, lot_id} =
      if method == "hotel_credit",
        do: HotelCredit.issue(group, operation["operation_id"], date, cash),
        else: {0, nil}

    disposition =
      cond do
        method == "hotel_credit" -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    for allocation <- cash do
      RoomAccounting.move(allocation, allocation.amount_cents, disposition, %{
        converted_lot_id: lot_id
      })
    end

    HotelCredit.settle(credit, refundable, date)

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in ids, do: Map.put(room, "status", "cancelled"), else: room
      end)

    totals = RoomAccounting.totals(%{group | rooms: rooms})

    group =
      update(
        group,
        Map.merge(totals, %{
          cash_refunded_cents: group.cash_refunded_cents + refunded,
          cash_retained_cents: group.cash_retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
        })
      )

    result = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: group.revision
    }

    if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result
  end

  defp apply_to_payment(operation) do
    id = operation["payment_operation_id"]
    unless identifier?(id), do: reject("invalid_operation")
    record = Payments.target(id) || reject("operation_not_found")
    chargeback = operation["type"] == "charge_back_payment"
    code = if chargeback, do: "payment_not_chargeable", else: "payment_not_reducible"

    # Even rejected payments and non-payment operations may address a group.
    # Resolve that group and check its revision before payment eligibility.
    group_id = record.result["group_id"] || record.submission["group_id"]
    group = if identifier?(group_id), do: Repo.get(Group, group_id)
    if group, do: check_revision(group, operation)
    unless Payments.cash_payment?(record), do: reject(code)
    unless group, do: reject("group_not_found")
    operation_date(operation)
    allocations = Payments.allocations(id)

    if chargeback do
      remaining = Enum.reject(allocations, &(&1.disposition == "reduced"))

      if remaining == [] or Enum.any?(remaining, &(&1.disposition == "charged_back")),
        do: reject(code)

      amount = RoomAccounting.sum(remaining)
      Payments.charge_back(id, allocations)

      settled = fn disposition ->
        remaining |> Enum.filter(&(&1.disposition == disposition)) |> RoomAccounting.sum()
      end

      group =
        update(
          group,
          Map.merge(RoomAccounting.totals(group), %{
            cash_refunded_cents: group.cash_refunded_cents - settled.("refunded"),
            cash_retained_cents: group.cash_retained_cents - settled.("retained"),
            cash_converted_to_credit_cents:
              group.cash_converted_to_credit_cents - settled.("converted_to_credit"),
            cash_charged_back_cents: group.cash_charged_back_cents + amount
          })
        )

      %{
        payment_operation_id: id,
        group_id: group.group_id,
        charged_back_cents: amount,
        outstanding_deposit_cents: outstanding(group),
        revision: group.revision
      }
    else
      held = Enum.filter(allocations, &(&1.disposition == "held"))
      if held == [], do: reject(code)
      require_fields(operation, ~w(amount_cents))
      amount = operation["amount_cents"]
      unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
      if amount > RoomAccounting.sum(held), do: reject("reduction_exceeds_held_cash")
      Payments.reduce(held, amount)

      group =
        update(
          group,
          Map.put(
            RoomAccounting.totals(group),
            :cash_reduced_cents,
            group.cash_reduced_cents + amount
          )
        )

      payment_result(group, amount) |> Map.put(:payment_operation_id, id)
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    window = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -window)
  end

  defp payment_amount(group, operation) do
    require_fields(operation, ~w(amount_cents))
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    amount
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp update(group, fields) do
    group
    |> Ecto.Changeset.change(Map.put(fields, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      Operations.reject(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0 and rate <= @max_cents

        _ ->
          false
      end)

    unless valid, do: reject("invalid_rooms")
    ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(ids)) != length(ids), do: reject("invalid_rooms")
    Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
  end

  defp validate_rooms(_), do: reject("invalid_rooms")
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp require_fields(operation, fields) do
    unless Enum.all?(fields, &Map.has_key?(operation, &1)), do: reject("invalid_operation")
  end

  defp operation_date(operation), do: parse_date(operation["occurred_on"], "invalid_operation")

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp parse_date(_, code), do: reject(code)

  defp shift_departure(arrival, nights) do
    departure = Date.add(arrival, nights)
    if departure.year > 9999, do: reject("invalid_stay")
    departure
  rescue
    ArgumentError -> reject("invalid_stay")
  end

  defp reject(code), do: Operations.reject(%{code: code})
end
