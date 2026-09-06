defmodule GroupStay do
  @moduledoc """
  Applies partner operations and reads reservation, cash and hotel-credit records.
  """

  import Ecto.Query
  alias GroupStay.{CreditLot, Group, Operation, Repo, Room, RoomAccounting}

  @operation_fields %{
    "open_group" => ~w(occurred_on guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(occurred_on amount_cents),
    "apply_hotel_credit" => ~w(occurred_on amount_cents),
    "reschedule_group" => ~w(occurred_on new_arrival_on),
    "cancel_group" => ~w(occurred_on),
    "cancel_rooms" => ~w(occurred_on room_ids),
    "reduce_cash_payment" => ~w(occurred_on amount_cents),
    "charge_back_payment" => ~w(occurred_on),
    "transfer_deposit" => ~w(occurred_on amount_cents)
  }
  @max_cents 9_223_372_036_854_775_807

  @doc "Processes operations in order, committing each result and its domain changes together."
  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Returns an operation's stored JSON result, or nil when it has not been remembered."
  def get_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  @doc "Returns the public group representation, or nil when it does not exist."
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

  @doc "Returns the current cash dispositions of a durable applied payment."
  def get_payment(payment_operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get_by(Operation, operation_id: payment_operation_id) do
          nil ->
            {:error, "operation_not_found"}

          payment ->
            if cash_payment?(payment) do
              {:ok,
               RoomAccounting.statement(
                 payment,
                 RoomAccounting.payment_allocations(payment_operation_id)
               )}
            else
              {:error, "payment_not_reconcilable"}
            end
        end
      end)

    result
  end

  @doc "Returns cash settlements and credit liability, evaluating expiry on the given date."
  def ledger(on \\ Date.utc_today()) do
    # All totals must observe one snapshot during funding, settlement and chargeback operations.
    {:ok, totals} =
      Repo.transaction(fn ->
        totals =
          Repo.one(
            from g in Group,
              select: %{
                cash_held_cents: coalesce(sum(g.deposit_paid_cents - g.credit_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(g.cash_converted_to_credit_cents), 0),
                cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
                cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0),
                credit_liability_cents: coalesce(sum(g.credit_paid_cents), 0)
              }
          )

        available =
          Repo.one(from lot in unexpired_lots(on), select: coalesce(sum(lot.remaining_cents), 0))

        totals
        |> Map.update!(:credit_liability_cents, &(&1 + available))
        |> Map.put(:credit_shortfall_cents, RoomAccounting.shortfall())
      end)

    totals
  end

  @doc "Returns the guest's available credit in expiry and source-operation order."
  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      guest_lots(guest_id, on)
      |> Repo.all()
      |> Enum.map(&Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  defp unexpired_lots(on) do
    from lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^on
  end

  defp guest_lots(guest_id, on) do
    from lot in unexpired_lots(on),
      where: lot.guest_id == ^guest_id,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp submit_operation(operation) do
    # SQLite must acquire its write lock before reading the operation or revision. A deferred
    # transaction can read an obsolete snapshot before attempting to write.
    # Queue writers in this VM before entering SQLite: concurrent native busy
    # waits can block first-use code loading in the process holding the write lock.
    # The immediate transaction still coordinates writers in separate OS processes.
    {:ok, result} =
      :global.trans(
        {{__MODULE__, Repo.get_dynamic_repo()}, self()},
        fn -> Repo.transaction(fn -> remember_operation(operation) end, mode: :immediate) end,
        [node()]
      )

    result
  end

  defp remember_operation(operation) do
    operation_id = if is_map(operation), do: operation["operation_id"]

    if valid_identifier?(operation_id) do
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil ->
          result = operation_result(operation, operation_id)

          Repo.insert!(%Operation{
            operation_id: operation_id,
            # Malformed types are still retained in full in the submitted payload.
            type: if(is_binary(operation["type"]), do: operation["type"]),
            payload: operation,
            result: result
          })

          result

        %Operation{payload: payload} = stored when payload === operation ->
          Operation.replay_result(stored)

        %Operation{} ->
          %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
      end
    else
      # Without a usable identifier there is no retry key to reserve.
      operation_result(operation, operation_id)
    end
  end

  defp operation_result(operation, operation_id) do
    # A handled rejection rolls back domain writes but leaves the outer transaction
    # available to remember that rejection. Exceptions escape and roll back everything.
    Repo.query!("SAVEPOINT operation_domain")

    result =
      try do
        Map.merge(apply_operation(operation), %{operation_id: operation_id, status: "applied"})
      catch
        {:operation_rejected, details} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          Map.merge(details, %{operation_id: operation_id, status: "rejected"})
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    result
  end

  defp apply_operation(operation) when is_map(operation) do
    unless valid_identifier?(operation["operation_id"]) and
             is_map_key(@operation_fields, operation["type"]) do
      reject("invalid_operation")
    end

    type = operation["type"]

    case type do
      "transfer_deposit" ->
        transfer_deposit(operation)

      type when type in ~w(reduce_cash_payment charge_back_payment) ->
        apply_payment_correction(type, operation)

      type ->
        unless valid_identifier?(operation["group_id"]), do: reject("invalid_operation")
        apply_group_operation(type, operation)
    end
  end

  defp apply_operation(_operation), do: reject("invalid_operation")

  defp apply_group_operation(type, operation) do
    case type do
      "open_group" ->
        require_fields(operation)
        open_group(operation)

      type ->
        group = Repo.get(Group, operation["group_id"]) || reject("group_not_found")
        check_revision(group, operation)
        require_fields(operation)
        unless group.status == "active", do: reject("group_not_active")
        update_group(type, group, operation)
    end
  end

  defp require_fields(operation) do
    unless Enum.all?(@operation_fields[operation["type"]], &Map.has_key?(operation, &1)) do
      reject("invalid_operation")
    end
  end

  defp check_revision(group, operation, field \\ "expected_revision") do
    if Map.has_key?(operation, field) and operation[field] !== group.revision do
      reject("stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation[field],
        actual_revision: group.revision
      })
    end
  end

  defp transfer_deposit(operation) do
    source_id = operation["source_group_id"]
    destination_id = operation["destination_group_id"]

    unless valid_identifier?(source_id) and valid_identifier?(destination_id),
      do: reject("invalid_operation")

    source = Repo.get(Group, source_id) || reject("group_not_found", %{group_id: source_id})

    destination =
      Repo.get(Group, destination_id) || reject("group_not_found", %{group_id: destination_id})

    check_revision(source, operation)
    check_revision(destination, operation, "destination_expected_revision")
    require_fields(operation)

    if source_id == destination_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination] do
      unless group.status == "active",
        do: reject("group_not_active", %{group_id: group.group_id})
    end

    date!(operation["occurred_on"], "invalid_operation")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > outstanding(destination), do: reject("transfer_exceeds_outstanding")

    credit = RoomAccounting.transfer(source_id, destination_id, amount)

    source =
      persist_update(source,
        deposit_paid_cents: source.deposit_paid_cents - amount,
        credit_paid_cents: source.credit_paid_cents - credit
      )

    destination =
      persist_update(destination,
        deposit_paid_cents: destination.deposit_paid_cents + amount,
        credit_paid_cents: destination.credit_paid_cents + credit
      )

    %{
      source_group_id: source_id,
      destination_group_id: destination_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(source),
      destination_outstanding_deposit_cents: outstanding(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    }
  end

  defp open_group(operation) do
    unless valid_identifier?(operation["guest_id"]) and
             valid_identifier?(operation["property_id"]) do
      reject("invalid_operation")
    end

    if Repo.get(Group, operation["group_id"]), do: reject("group_already_exists")

    booked_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["arrival_on"], "invalid_stay")
    departure_on = date!(operation["departure_on"], "invalid_stay")
    nights = Date.diff(departure_on, arrival_on)
    unless nights > 0, do: reject("invalid_stay")

    rate_plan = operation["rate_plan"]
    unless rate_plan in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")

    rooms =
      operation["rooms"]
      |> validate_rooms()
      |> Enum.with_index(fn room, position ->
        lodging = nights * room["nightly_rate_cents"]
        due = if rate_plan == "flexible", do: round_percentage(lodging, 20), else: lodging

        %Room{
          group_id: operation["group_id"],
          room_id: room["room_id"],
          position: position,
          nightly_rate_cents: room["nightly_rate_cents"],
          lodging_total_cents: lodging,
          deposit_due_cents: due
        }
      end)

    lodging_total = RoomAccounting.sum(rooms, :lodging_total_cents)
    deposit_due = RoomAccounting.sum(rooms, :deposit_due_cents)

    unless lodging_total <= @max_cents, do: reject("invalid_rooms")

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

    Enum.each(rooms, &Repo.insert!/1)

    %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: group.revision}
  end

  defp update_group("record_cash_payment", group, operation) do
    date!(operation["occurred_on"], "invalid_operation")
    amount = payment_amount!(group, operation)

    RoomAccounting.allocate(group.group_id, operation["operation_id"], amount)
    group = persist_update(group, deposit_paid_cents: group.deposit_paid_cents + amount)

    payment_result(group, amount)
  end

  defp update_group("apply_hotel_credit", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_operation")
    amount = payment_amount!(group, operation)
    lots = Repo.all(guest_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    Enum.reduce_while(lots, amount, fn lot, needed ->
      taken = min(lot.remaining_cents, needed)
      lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - taken) |> Repo.update!()

      RoomAccounting.allocate(group.group_id, operation["operation_id"], taken, lot.id)

      if taken == needed, do: {:halt, 0}, else: {:cont, needed - taken}
    end)

    group =
      persist_update(group,
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount
      )

    payment_result(group, amount)
  end

  defp update_group("reschedule_group", group, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_stay")
    arrival_on = date!(operation["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival_on, occurred_on) == :gt, do: reject("invalid_stay")
    departure_on = shift_departure(arrival_on, Date.diff(group.departure_on, group.arrival_on))
    group = persist_update(group, arrival_on: arrival_on, departure_on: departure_on)

    %{
      group_id: group.group_id,
      new_arrival_on: group.arrival_on,
      new_departure_on: group.departure_on,
      policy_version: group.policy_version,
      refundable_until: refundable_until(group),
      revision: group.revision
    }
  end

  defp update_group(type, group, operation) when type in ~w(cancel_group cancel_rooms) do
    rooms = RoomAccounting.active_rooms(group.group_id)

    selected =
      if type == "cancel_rooms", do: select_rooms!(rooms, operation["room_ids"]), else: rooms

    settle_rooms(group, selected, operation)
  end

  defp select_rooms!(rooms, ids) do
    unless is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids),
      do: reject("invalid_rooms")

    selected = Enum.filter(rooms, &(&1.room_id in ids))
    unless length(selected) == length(ids), do: reject("invalid_rooms")
    selected
  end

  defp settle_rooms(group, rooms, operation) do
    occurred_on = date!(operation["occurred_on"], "invalid_operation")
    refund_method = Map.get(operation, "refund_method", "cash")
    unless refund_method in ~w(cash hotel_credit), do: reject("invalid_refund_method")
    deadline = refundable_until(group)
    refundable = deadline != nil and Date.compare(occurred_on, deadline) != :gt

    if refund_method == "hotel_credit" and not refundable,
      do: reject("refund_method_not_available")

    allocations = RoomAccounting.held_allocations(rooms)
    cash = RoomAccounting.sum_cash(allocations)
    credit = RoomAccounting.sum_credit(allocations)
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and refund_method == "hotel_credit", do: cash, else: 0

    issued =
      if converted > 0,
        do: issue_credit(group, operation, occurred_on, converted, allocations),
        else: 0

    disposition =
      cond do
        not refundable -> :retained_cents
        refund_method == "cash" -> :refunded_cents
        true -> :converted_to_credit_cents
      end

    RoomAccounting.settle(allocations, disposition, refundable, occurred_on)
    ids = Enum.map(rooms, & &1.id)

    Repo.update_all(from(r in Room, where: r.id in ^ids),
      set: [status: "cancelled", deposit_due_cents: 0]
    )

    active = RoomAccounting.active_rooms(group.group_id)

    group =
      persist_update(group,
        status: if(active == [], do: "cancelled", else: "active"),
        lodging_total_cents: RoomAccounting.sum(active, :lodging_total_cents),
        deposit_due_cents: RoomAccounting.sum(active, :deposit_due_cents),
        deposit_paid_cents: group.deposit_paid_cents - cash - credit,
        credit_paid_cents: group.credit_paid_cents - credit,
        cash_refunded_cents: group.cash_refunded_cents + refunded,
        cash_retained_cents: group.cash_retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      )

    result = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: group.revision
    }

    if operation["type"] == "cancel_rooms",
      do: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
      else: result
  end

  defp issue_credit(group, operation, occurred_on, cash, allocations) do
    issued = RoomAccounting.bonus_value(cash)
    expires_on = Date.add(occurred_on, 365)

    unless expires_on.year in -9999..9999 and issued <= @max_cents,
      do: reject("invalid_operation")

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_group_id: group.group_id,
        source_operation_id: operation["operation_id"],
        expires_on: expires_on,
        issued_cents: issued,
        remaining_cents: issued
      })

    RoomAccounting.issue_entitlements(lot, allocations)
    issued
  end

  defp cash_payment?(payment),
    do: payment.type == "record_cash_payment" and payment.result["status"] == "applied"

  defp apply_payment_correction(type, operation) do
    id = operation["payment_operation_id"]
    unless valid_identifier?(id), do: reject("invalid_operation")
    payment = Repo.get_by(Operation, operation_id: id) || reject("operation_not_found")

    code =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    unless cash_payment?(payment), do: reject(code)
    group = Repo.get(Group, payment.result["group_id"]) || reject("group_not_found")
    check_revision(group, operation)
    require_fields(operation)
    date!(operation["occurred_on"], "invalid_operation")
    allocations = RoomAccounting.payment_allocations(id)
    statement = RoomAccounting.statement(payment, allocations)
    correct_payment(type, group, payment, allocations, statement, operation)
  end

  defp correct_payment("reduce_cash_payment", group, payment, allocations, statement, operation) do
    if statement.held_cents == 0, do: reject("payment_not_reducible")
    amount = operation["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > statement.held_cents, do: reject("reduction_exceeds_held_cash")

    group =
      allocations
      |> RoomAccounting.reduce_cash(amount)
      |> Map.new(fn {group_id, removed} ->
        {group_id, [deposit_paid_cents: -removed, cash_reduced_cents: removed]}
      end)
      |> persist_correction_groups(group)

    payment_result(group, amount) |> Map.put(:payment_operation_id, payment.operation_id)
  end

  defp correct_payment("charge_back_payment", group, payment, allocations, statement, _operation) do
    amount = statement.recorded_cents - statement.reduced_cents
    if amount == 0 or statement.charged_back_cents > 0, do: reject("payment_not_chargeable")
    RoomAccounting.charge_back(payment, allocations)

    group =
      allocations
      |> Enum.group_by(& &1.group_id)
      |> Enum.flat_map(fn {group_id, rows} ->
        held = RoomAccounting.sum(rows, :held_cents)
        refunded = RoomAccounting.sum(rows, :refunded_cents)
        retained = RoomAccounting.sum(rows, :retained_cents)
        converted = RoomAccounting.sum(rows, :converted_to_credit_cents)
        charged = held + refunded + retained + converted

        if charged == 0 do
          []
        else
          [
            {group_id,
             [
               deposit_paid_cents: -held,
               cash_refunded_cents: -refunded,
               cash_retained_cents: -retained,
               cash_converted_to_credit_cents: -converted,
               cash_charged_back_cents: charged
             ]}
          ]
        end
      end)
      |> Map.new()
      |> persist_correction_groups(group)

    %{
      payment_operation_id: payment.operation_id,
      group_id: group.group_id,
      charged_back_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp persist_correction_groups(deltas, original) do
    # The original payment group is always addressed, even if all its cash has moved away.
    deltas
    |> Map.put_new(original.group_id, [])
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new(fn {group_id, changes} ->
      group = if group_id == original.group_id, do: original, else: Repo.get!(Group, group_id)

      changes =
        Enum.map(changes, fn {field, delta} -> {field, Map.fetch!(group, field) + delta} end)

      {group_id, persist_update(group, changes)}
    end)
    |> Map.fetch!(original.group_id)
  end

  defp payment_amount!(group, operation) do
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

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    days = if group.policy_version == "flex-14", do: 14, else: 30
    Date.add(group.arrival_on, -days)
  end

  defp persist_update(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0 and
          room["nightly_rate_cents"] <= @max_cents
      end)

    unless valid, do: reject("invalid_rooms")
    identifiers = Enum.map(rooms, & &1["room_id"])
    unless length(Enum.uniq(identifiers)) == length(rooms), do: reject("invalid_rooms")
    rooms
  end

  defp validate_rooms(_rooms), do: reject("invalid_rooms")

  # Integer arithmetic preserves cent precision, including half-cent rounding.
  defp round_percentage(amount, percent), do: div(amount * percent + 50, 100)
  defp valid_identifier?(value), do: is_binary(value) and value != ""
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

  defp date!(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> reject(code)
    end
  end

  defp date!(_value, code), do: reject(code)

  defp shift_departure(arrival_on, nights) do
    departure_on = Date.add(arrival_on, nights)
    # Date.add/2 can produce years outside the API's ISO 8601 date format.
    unless departure_on.year in -9999..9999, do: reject("invalid_stay")
    departure_on
  end

  defp reject(code, details \\ %{}),
    do: throw({:operation_rejected, Map.put(details, :code, code)})

  defp group_data(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, cash_paid(group))
    |> Map.put(:refundable_until, refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
    |> Map.put(:rooms, RoomAccounting.room_data(group.rooms))
  end
end
