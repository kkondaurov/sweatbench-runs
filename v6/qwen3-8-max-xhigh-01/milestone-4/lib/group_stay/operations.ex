defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in batch order and reports the outcome of each.

  Every operation runs in its own transaction, committing its idempotency
  record together with any domain changes. A handled rejection leaves domain
  state unchanged but still commits its record, and does not stop later
  operations, while an applied operation's changes are visible to the
  operations that follow it.

  Operations carrying an identifier are durably idempotent: the first
  operation received for an `operation_id` is processed normally, an
  equivalent payload returns the stored result without reading or changing
  current domain state, and a different payload is rejected with
  `operation_id_conflict`.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Groups.{CashPayment, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @operation_types %{
    "open_group" => :open_group,
    "record_cash_payment" => :record_cash_payment,
    "reschedule_group" => :reschedule_group,
    "cancel_group" => :cancel_group,
    "apply_hotel_credit" => :apply_hotel_credit,
    "cancel_rooms" => :cancel_rooms,
    "reduce_cash_payment" => :reduce_cash_payment,
    "charge_back_payment" => :charge_back_payment
  }

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_available_days 365

  @doc """
  Processes operations in order, returning one result map per operation.
  """
  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc """
  The result remembered for an operation identifier, or `nil` when the
  identifier has not been recorded.
  """
  def recorded_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      %Record{} = record -> record.result
    end
  end

  defp process_operation(raw) when is_map(raw) do
    case fetch(raw, "operation_id") do
      {:ok, operation_id} when is_binary(operation_id) -> run_durable(operation_id, raw)
      _ -> process_untracked(raw)
    end
  end

  defp process_operation(raw), do: process_untracked(raw)

  defp process_untracked(raw) do
    case parse_operation(raw) do
      {:ok, op} -> run(op)
      {:error, operation_id} -> rejected(operation_id, "invalid_operation")
    end
  end

  defp run(op) do
    {:ok, result} = Repo.transaction(fn -> apply_operation(op) end)
    result
  end

  # Durable idempotency

  defp run_durable(operation_id, raw) do
    case Repo.transaction(fn -> apply_durable(operation_id, raw) end) do
      {:ok, result} ->
        result

      {:error, :operation_id_race} ->
        # A concurrent request committed this identifier first. Its record is
        # authoritative; this attempt's changes were rolled back.
        Record
        |> Repo.get_by!(operation_id: operation_id)
        |> replay(raw)
    end
  end

  defp apply_durable(operation_id, raw) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> record_new_operation(operation_id, raw)
      %Record{} = record -> replay(record, raw)
    end
  end

  defp record_new_operation(operation_id, raw) do
    result =
      case parse_operation(raw) do
        {:ok, op} -> apply_operation(op)
        {:error, _operation_id} -> rejected(operation_id, "invalid_operation")
      end

    %Record{}
    |> Record.create_changeset(%{
      operation_id: operation_id,
      type: submitted_type(raw),
      payload: normalize(raw),
      result: result
    })
    |> Repo.insert()
    |> case do
      {:ok, _record} -> result
      {:error, _changeset} -> Repo.rollback(:operation_id_race)
    end
  end

  defp replay(record, raw) do
    if normalize(raw) == record.payload do
      record.result
    else
      rejected(record.operation_id, "operation_id_conflict")
    end
  end

  defp submitted_type(raw) do
    case fetch(raw, "type") do
      {:ok, type} when is_binary(type) -> type
      _ -> nil
    end
  end

  # Payload equivalence: JSON object key order is insignificant, while array
  # order and values remain significant. Decoded maps compare structurally,
  # so normalizing keys to strings is enough to compare submissions.
  defp normalize(%_{} = value), do: value

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), normalize(val)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value), do: value

  # Applying operations

  defp apply_operation(%{type: :open_group} = op) do
    with :ok <- ensure_group_absent(op),
         {:ok, stay} <- parse_stay(op),
         {:ok, rooms} <- parse_rooms(op.rooms),
         :ok <- ensure_rate_plan(op.rate_plan) do
      open_group(op, stay, rooms)
    else
      {:rejected, code} -> rejected(op.operation_id, code, %{group_id: op.group_id})
    end
  end

  defp apply_operation(%{type: :record_cash_payment} = op) do
    with {:ok, group} <- fetch_group(op),
         group <- Accounting.ensure_brought_forward(group),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, amount_cents} <- ensure_amount(op),
         :ok <- ensure_within_outstanding(op, group, amount_cents) do
      record_cash_payment(op, group, amount_cents)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :reschedule_group} = op) do
    with {:ok, group} <- fetch_group(op),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, new_arrival_on, new_departure_on} <- ensure_reschedule(op, group) do
      reschedule_group(op, group, new_arrival_on, new_departure_on)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :cancel_group} = op) do
    with {:ok, group} <- fetch_group(op),
         group <- Accounting.ensure_brought_forward(group),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         :ok <- ensure_refund_method_available(op, group) do
      cancel_group(op, group)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :apply_hotel_credit} = op) do
    with {:ok, group} <- fetch_group(op),
         group <- Accounting.ensure_brought_forward(group),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, amount_cents} <- ensure_amount(op),
         :ok <- ensure_within_outstanding(op, group, amount_cents),
         :ok <- ensure_sufficient_credit(op, group, amount_cents) do
      apply_hotel_credit(op, group, amount_cents)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :cancel_rooms} = op) do
    with {:ok, group} <- fetch_group(op),
         group <- Accounting.ensure_brought_forward(group),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_active(op, group),
         {:ok, rooms} <- ensure_rooms(op, group),
         :ok <- ensure_refund_method_available(op, group) do
      cancel_rooms(op, group, rooms)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :reduce_cash_payment} = op) do
    with {:ok, record} <- fetch_payment_record(op),
         {:ok, payment, group} <- fetch_reducible_payment(op, record),
         group <- Accounting.ensure_brought_forward(group),
         op <- Map.put(op, :group_id, group.group_id),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_payment_has_held(op, payment),
         {:ok, amount_cents} <- ensure_amount(op),
         :ok <- ensure_within_held(op, payment, amount_cents) do
      reduce_cash_payment(op, payment, group, amount_cents)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_operation(%{type: :charge_back_payment} = op) do
    with {:ok, record} <- fetch_payment_record(op),
         {:ok, payment, group} <- fetch_applied_payment(op, record, "payment_not_chargeable"),
         group <- Accounting.ensure_brought_forward(group),
         op <- Map.put(op, :group_id, group.group_id),
         :ok <- ensure_expected_revision(op, group),
         :ok <- ensure_chargeable(op, payment) do
      charge_back_payment(op, payment, group)
    else
      {:rejected, result} -> result
    end
  end

  # open_group

  defp ensure_group_absent(op) do
    if Repo.get_by(Group, group_id: op.group_id) do
      {:rejected, "group_already_exists"}
    else
      :ok
    end
  end

  defp parse_stay(op) do
    with {:ok, arrival_on} <- parse_date(op.arrival_on),
         {:ok, departure_on} <- parse_date(op.departure_on),
         nights when nights >= 1 <- Date.diff(departure_on, arrival_on) do
      {:ok, %{arrival_on: arrival_on, departure_on: departure_on, nights: nights}}
    else
      _ -> {:rejected, "invalid_stay"}
    end
  end

  defp parse_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) and unique_room_ids?(parsed) do
      {:ok, Enum.map(parsed, fn {:ok, room} -> room end)}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp parse_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp parse_room(room) when is_map(room) do
    with {:ok, room_id} when is_binary(room_id) <- fetch(room, "room_id"),
         {:ok, rate} when is_integer(rate) and rate > 0 <- fetch(room, "nightly_rate_cents") do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      _ -> :error
    end
  end

  defp parse_room(_room), do: :error

  defp unique_room_ids?(parsed) do
    ids = Enum.map(parsed, fn {:ok, room} -> room.room_id end)
    length(ids) == length(Enum.uniq(ids))
  end

  defp ensure_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp ensure_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp open_group(op, stay, rooms) do
    deposit_due_cents = deposit_due(stay.nights, rooms, op.rate_plan)

    changeset =
      Group.create_changeset(%Group{}, %{
        group_id: op.group_id,
        guest_id: op.guest_id,
        property_id: op.property_id,
        booked_on: op.occurred_on,
        arrival_on: stay.arrival_on,
        departure_on: stay.departure_on,
        rate_plan: op.rate_plan,
        policy_version: Group.policy_version_for(op.rate_plan, op.occurred_on),
        status: "active",
        revision: 1,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        outstanding_deposit_cents: deposit_due_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        insert_rooms!(group, rooms, stay.nights, op.rate_plan)

        applied(op.operation_id, %{
          group_id: op.group_id,
          deposit_due_cents: deposit_due_cents,
          revision: group.revision
        })

      {:error, _changeset} ->
        rejected(op.operation_id, "group_already_exists", %{group_id: op.group_id})
    end
  end

  defp insert_rooms!(group, rooms, nights, rate_plan) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      %Room{}
      |> Room.create_changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        status: "active",
        deposit_due_cents: room_deposit(room.nightly_rate_cents * nights, rate_plan)
      })
      |> Repo.insert!()
    end)
  end

  defp deposit_due(nights, rooms, rate_plan) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room_deposit(room.nightly_rate_cents * nights, rate_plan)
    end)
  end

  defp room_deposit(lodging_cents, "flexible") do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end

  # record_cash_payment

  defp record_cash_payment(op, group, amount_cents) do
    new_revision = group.revision + 1

    payment =
      %CashPayment{}
      |> CashPayment.create_changeset(%{
        group_id: group.id,
        amount_cents: amount_cents,
        occurred_on: op.occurred_on,
        operation_id: op.operation_id
      })
      |> Repo.insert!()

    Accounting.allocate_cash(group, amount_cents, payment.id)

    totals = active_totals(group)

    group
    |> change(Map.put(totals, :revision, new_revision))
    |> Repo.update!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      amount_cents: amount_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents,
      revision: new_revision
    })
  end

  defp ensure_amount(%{amount_cents: amount_cents})
       when is_integer(amount_cents) and amount_cents > 0 do
    {:ok, amount_cents}
  end

  defp ensure_amount(op) do
    {:rejected, rejected(op.operation_id, "invalid_amount", %{group_id: op.group_id})}
  end

  defp ensure_within_outstanding(op, group, amount_cents) do
    if amount_cents > Accounting.outstanding(group) do
      {:rejected,
       rejected(op.operation_id, "payment_exceeds_outstanding", %{group_id: op.group_id})}
    else
      :ok
    end
  end

  # reschedule_group

  defp ensure_reschedule(op, group) do
    with {:ok, new_arrival_on} <- parse_date(op.new_arrival_on),
         :gt <- Date.compare(new_arrival_on, op.occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      {:ok, new_arrival_on, Date.add(new_arrival_on, nights)}
    else
      _ -> {:rejected, rejected(op.operation_id, "invalid_stay", %{group_id: op.group_id})}
    end
  end

  defp reschedule_group(op, group, new_arrival_on, new_departure_on) do
    new_revision = group.revision + 1

    group
    |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: new_revision)
    |> Repo.update!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      new_arrival_on: new_arrival_on,
      new_departure_on: new_departure_on,
      policy_version: group.policy_version,
      refundable_until: Group.refundable_until(group, new_arrival_on),
      revision: new_revision
    })
  end

  # cancel_group / cancel_rooms

  defp ensure_refund_method_available(%{refund_method: "hotel_credit"} = op, group) do
    if Group.refundable?(group, op.occurred_on) do
      :ok
    else
      {:rejected,
       rejected(op.operation_id, "refund_method_not_available", %{group_id: op.group_id})}
    end
  end

  defp ensure_refund_method_available(_op, _group), do: :ok

  defp cancel_group(op, group) do
    rooms = Accounting.active_rooms(group.id)
    settle_rooms(op, group, rooms, rooms)
  end

  defp ensure_rooms(op, group) do
    room_ids = op.room_ids
    active = Accounting.active_rooms(group.id)

    cond do
      not is_list(room_ids) or room_ids == [] ->
        {:rejected, rejected(op.operation_id, "invalid_rooms", %{group_id: op.group_id})}

      not all_string_and_distinct?(room_ids) ->
        {:rejected, rejected(op.operation_id, "invalid_rooms", %{group_id: op.group_id})}

      true ->
        by_id = Map.new(active, fn room -> {room.room_id, room} end)

        if Enum.all?(room_ids, &Map.has_key?(by_id, &1)) do
          selected =
            active
            |> Enum.filter(&(&1.room_id in room_ids))

          {:ok, selected}
        else
          {:rejected, rejected(op.operation_id, "invalid_rooms", %{group_id: op.group_id})}
        end
    end
  end

  defp all_string_and_distinct?(room_ids) do
    Enum.all?(room_ids, &is_binary/1) and length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp cancel_rooms(op, group, selected_rooms) do
    cancelled_ids = Enum.map(selected_rooms, & &1.room_id)
    result = settle_rooms(op, group, selected_rooms, cancelled_ids)
    result
  end

  # Settles the selected rooms' allocated cash and credit. `cancelled_ids` are
  # the room identifiers reported back, in the group's original room order.
  defp settle_rooms(op, group, selected_rooms, cancelled_ids) do
    new_revision = group.revision + 1
    refundable? = Group.refundable?(group, op.occurred_on)

    settle_credit_allocations(selected_rooms, refundable?)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      settle_cash_allocations(op, group, selected_rooms, refundable?)

    selected_rooms
    |> Enum.each(fn room ->
      room |> change(status: "cancelled") |> Repo.update!()
    end)

    totals = active_totals(group)

    status =
      case Accounting.active_rooms(group.id) do
        [] -> "cancelled"
        _ -> group.status
      end

    outstanding =
      case Accounting.active_rooms(group.id) do
        [] -> 0
        _ -> totals.outstanding_deposit_cents
      end

    group
    |> change(
      Map.merge(totals, %{
        status: status,
        outstanding_deposit_cents: outstanding,
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        converted_to_credit_cents: group.converted_to_credit_cents + converted_cents,
        revision: new_revision
      })
    )
    |> Repo.update!()

    case op.type do
      :cancel_group ->
        applied(op.operation_id, %{
          group_id: op.group_id,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: new_revision
        })

      :cancel_rooms ->
        applied(op.operation_id, %{
          group_id: op.group_id,
          cancelled_room_ids: cancelled_ids,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: new_revision
        })
    end
  end

  defp settle_cash_allocations(op, group, selected_rooms, refundable?) do
    allocations = held_cash_allocations(selected_rooms)
    combined_cash = Enum.reduce(allocations, 0, fn a, sum -> sum + a.amount_cents end)

    cond do
      not refundable? ->
        Enum.each(allocations, fn a -> a |> change(state: "retained") |> Repo.update!() end)
        {0, combined_cash, 0, 0}

      op.refund_method == "hotel_credit" ->
        lot_id = issue_room_credit_lot(group, combined_cash, op)

        Enum.each(allocations, fn a ->
          a |> change(state: "converted", credit_lot_id: lot_id) |> Repo.update!()
        end)

        {0, 0, combined_cash, issued_for(combined_cash)}

      true ->
        Enum.each(allocations, fn a -> a |> change(state: "refunded") |> Repo.update!() end)
        {combined_cash, 0, 0, 0}
    end
  end

  defp held_cash_allocations(rooms) do
    rooms
    |> Enum.flat_map(fn room -> Accounting.room_cash_allocations(room.id) end)
  end

  defp issued_for(0), do: 0

  defp issued_for(combined_cash) do
    combined_cash + round_half_up(combined_cash * @credit_bonus_percent, 100)
  end

  defp issue_room_credit_lot(_group, 0, _op), do: nil

  defp issue_room_credit_lot(group, combined_cash, op) do
    bonus_cents = round_half_up(combined_cash * @credit_bonus_percent, 100)
    issued_cents = combined_cash + bonus_cents

    lot =
      %CreditLot{}
      |> CreditLot.create_changeset(%{
        guest_id: group.guest_id,
        source_operation_id: op.operation_id,
        issued_cents: issued_cents,
        remaining_cents: issued_cents,
        issued_on: op.occurred_on,
        expires_on: Date.add(op.occurred_on, @credit_available_days + 1),
        group_id: group.id,
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    lot.id
  end

  defp settle_credit_allocations(selected_rooms, refundable?) do
    selected_rooms
    |> Enum.flat_map(fn room -> Accounting.room_credit_allocations(room.id) end)
    |> Enum.each(fn allocation ->
      if refundable? do
        restore_credit_allocation(allocation)
      else
        allocation |> change(state: "consumed") |> Repo.update!()
      end
    end)
  end

  # Restoring returns the credit to its original lot. Any unrecovered clawback
  # on the lot is extinguished first; only the excess becomes available again.
  # A lot whose expiry is already past simply keeps the excess out of the
  # available balance, reducing the liability.
  defp restore_credit_allocation(allocation) do
    lot = Repo.get!(CreditLot, allocation.lot_id)

    absorb = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
    restorable = allocation.amount_cents - absorb

    lot
    |> change(
      remaining_cents: lot.remaining_cents + restorable,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb
    )
    |> Repo.update!()

    allocation |> change(state: "restored") |> Repo.update!()
  end

  defp active_totals(group) do
    due = Accounting.deposit_due(group)
    cash = Accounting.cash_paid(group)
    credit = Accounting.credit_paid(group)

    %{
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      outstanding_deposit_cents: due - cash - credit
    }
  end

  # apply_hotel_credit

  defp ensure_sufficient_credit(op, group, amount_cents) do
    if available_credit(group.guest_id, op.occurred_on) >= amount_cents do
      :ok
    else
      {:rejected, rejected(op.operation_id, "insufficient_credit", %{group_id: op.group_id})}
    end
  end

  defp available_credit(guest_id, as_of) do
    guest_id
    |> available_lots(as_of)
    |> Enum.reduce(0, fn lot, total -> total + lot.remaining_cents end)
  end

  defp available_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end

  defp apply_hotel_credit(op, group, amount_cents) do
    new_revision = group.revision + 1

    applications =
      group.guest_id
      |> available_lots(op.occurred_on)
      |> consume_lots(amount_cents, group, op.occurred_on, op.operation_id)

    Accounting.allocate_credit(group, applications)

    totals = active_totals(group)

    group
    |> change(Map.put(totals, :revision, new_revision))
    |> Repo.update!()

    applied(op.operation_id, %{
      group_id: op.group_id,
      amount_cents: amount_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents,
      revision: new_revision
    })
  end

  defp consume_lots(_lots, 0, _group, _occurred_on, _operation_id), do: []

  defp consume_lots([lot | lots], remaining_cents, group, occurred_on, operation_id) do
    taken_cents = min(lot.remaining_cents, remaining_cents)

    lot
    |> change(remaining_cents: lot.remaining_cents - taken_cents)
    |> Repo.update!()

    application =
      %CreditApplication{}
      |> CreditApplication.create_changeset(%{
        group_id: group.id,
        lot_id: lot.id,
        amount_cents: taken_cents,
        occurred_on: occurred_on,
        state: "applied",
        operation_id: operation_id
      })
      |> Repo.insert!()

    [
      application
      | consume_lots(lots, remaining_cents - taken_cents, group, occurred_on, operation_id)
    ]
  end

  # reduce_cash_payment / charge_back_payment

  defp fetch_payment_record(op) do
    case Repo.get_by(Record, operation_id: op.payment_operation_id) do
      nil ->
        {:rejected, rejected(op.operation_id, "operation_not_found", %{})}

      record ->
        {:ok, record}
    end
  end

  defp fetch_reducible_payment(op, record) do
    fetch_applied_payment(op, record, "payment_not_reducible")
  end

  defp fetch_applied_payment(op, record, code) do
    applied_cash_payment? =
      record.type == "record_cash_payment" and get_in(record.result, ["status"]) == "applied"

    if not applied_cash_payment? do
      {:rejected, rejected(op.operation_id, code, %{})}
    else
      case Repo.get_by(CashPayment, operation_id: record.operation_id) do
        nil ->
          {:rejected, rejected(op.operation_id, code, %{})}

        payment ->
          group = Repo.get!(Group, payment.group_id)
          {:ok, payment, group}
      end
    end
  end

  defp ensure_payment_has_held(op, payment) do
    if Accounting.held_cash_for_payment(payment) > 0 do
      :ok
    else
      {:rejected, rejected(op.operation_id, "payment_not_reducible", %{group_id: op.group_id})}
    end
  end

  defp ensure_within_held(op, payment, amount_cents) do
    if amount_cents > Accounting.held_cash_for_payment(payment) do
      {:rejected,
       rejected(op.operation_id, "reduction_exceeds_held_cash", %{group_id: op.group_id})}
    else
      :ok
    end
  end

  defp reduce_cash_payment(op, payment, group, amount_cents) do
    new_revision = group.revision + 1

    Accounting.reduce_held(payment, amount_cents)

    totals = active_totals(group)

    group
    |> change(
      Map.merge(totals, %{
        cash_reduced_cents: group.cash_reduced_cents + amount_cents,
        revision: new_revision
      })
    )
    |> Repo.update!()

    applied(op.operation_id, %{
      payment_operation_id: op.payment_operation_id,
      group_id: group.group_id,
      amount_cents: amount_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents,
      revision: new_revision
    })
  end

  defp ensure_chargeable(op, payment) do
    disposition = Accounting.payment_disposition(payment)
    reduced = Map.get(disposition, "reduced", 0)
    charged_back = Map.get(disposition, "charged_back", 0)

    cond do
      charged_back > 0 ->
        {:rejected, rejected(op.operation_id, "payment_not_chargeable", %{group_id: op.group_id})}

      reduced >= payment.amount_cents ->
        {:rejected, rejected(op.operation_id, "payment_not_chargeable", %{group_id: op.group_id})}

      true ->
        :ok
    end
  end

  defp charge_back_payment(op, payment, group) do
    new_revision = group.revision + 1

    {charged_back_cents, disposition} = Accounting.charge_back_payment(payment)

    held = Map.get(disposition, "held", 0)
    refunded = Map.get(disposition, "refunded", 0)
    retained = Map.get(disposition, "retained", 0)
    converted = Map.get(disposition, "converted", 0)

    totals = active_totals(group)

    group
    |> change(
      Map.merge(totals, %{
        refunded_cents: group.refunded_cents - refunded,
        retained_cents: group.retained_cents - retained,
        converted_to_credit_cents: group.converted_to_credit_cents - converted,
        cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents,
        revision: new_revision
      })
    )
    |> Repo.update!()

    _ = held

    applied(op.operation_id, %{
      payment_operation_id: op.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents,
      revision: new_revision
    })
  end

  # Shared validation

  defp fetch_group(op) do
    case Repo.get_by(Group, group_id: op.group_id) do
      nil ->
        {:rejected, rejected(op.operation_id, "group_not_found", %{group_id: op.group_id})}

      group ->
        {:ok, group}
    end
  end

  defp ensure_expected_revision(%{expected_revision: nil}, _group), do: :ok

  defp ensure_expected_revision(op, group) do
    if op.expected_revision == group.revision do
      :ok
    else
      {:rejected,
       rejected(op.operation_id, "stale_revision", %{
         group_id: op.group_id,
         expected_revision: op.expected_revision,
         actual_revision: group.revision
       })}
    end
  end

  defp ensure_active(_op, %Group{status: "active"}), do: :ok

  defp ensure_active(op, _group) do
    {:rejected, rejected(op.operation_id, "group_not_active", %{group_id: op.group_id})}
  end

  # Parsing raw operations

  defp parse_operation(raw) when is_map(raw) do
    operation_id = optional_string(raw, "operation_id")

    with {:ok, type} <- fetch_type(raw),
         {:ok, occurred_on} <- fetch_occurred_on(raw),
         {:ok, fields} <- parse_fields(type, raw) do
      {:ok,
       %{
         type: type,
         operation_id: operation_id,
         occurred_on: occurred_on
       }
       |> Map.merge(fields)}
    else
      :error -> {:error, operation_id}
    end
  end

  defp parse_operation(_raw), do: {:error, nil}

  defp parse_fields(:open_group, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, guest_id} <- fetch_string(raw, "guest_id"),
         {:ok, property_id} <- fetch_string(raw, "property_id"),
         {:ok, arrival_on} <- fetch_present(raw, "arrival_on"),
         {:ok, departure_on} <- fetch_present(raw, "departure_on"),
         {:ok, rate_plan} <- fetch_present(raw, "rate_plan"),
         {:ok, rooms} <- fetch_present(raw, "rooms") do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp parse_fields(:record_cash_payment, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, amount_cents} <- fetch_present(raw, "amount_cents"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{group_id: group_id, amount_cents: amount_cents, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:reschedule_group, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, new_arrival_on} <- fetch_present(raw, "new_arrival_on"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{group_id: group_id, new_arrival_on: new_arrival_on, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:cancel_group, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, refund_method} <- fetch_refund_method(raw),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{group_id: group_id, refund_method: refund_method, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:apply_hotel_credit, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, amount_cents} <- fetch_present(raw, "amount_cents"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{group_id: group_id, amount_cents: amount_cents, expected_revision: expected_revision}}
    end
  end

  defp parse_fields(:cancel_rooms, raw) do
    with {:ok, group_id} <- fetch_string(raw, "group_id"),
         {:ok, room_ids} <- fetch_present(raw, "room_ids"),
         {:ok, refund_method} <- fetch_refund_method(raw),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{
         group_id: group_id,
         room_ids: room_ids,
         refund_method: refund_method,
         expected_revision: expected_revision
       }}
    end
  end

  defp parse_fields(:reduce_cash_payment, raw) do
    with {:ok, payment_operation_id} <- fetch_string(raw, "payment_operation_id"),
         {:ok, amount_cents} <- fetch_present(raw, "amount_cents"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok,
       %{
         payment_operation_id: payment_operation_id,
         amount_cents: amount_cents,
         expected_revision: expected_revision
       }}
    end
  end

  defp parse_fields(:charge_back_payment, raw) do
    with {:ok, payment_operation_id} <- fetch_string(raw, "payment_operation_id"),
         {:ok, expected_revision} <- fetch_expected_revision(raw) do
      {:ok, %{payment_operation_id: payment_operation_id, expected_revision: expected_revision}}
    end
  end

  defp fetch_type(raw) do
    with {:ok, type} <- fetch(raw, "type"),
         {:ok, operation_type} <- Map.fetch(@operation_types, type) do
      {:ok, operation_type}
    else
      _ -> :error
    end
  end

  defp fetch_occurred_on(raw) do
    with {:ok, value} <- fetch(raw, "occurred_on"),
         {:ok, date} <- parse_date(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp fetch_expected_revision(raw) do
    case fetch(raw, "expected_revision") do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, nil}
    end
  end

  defp fetch_refund_method(raw) do
    case fetch(raw, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, nil} -> {:ok, "cash"}
      {:ok, "cash"} -> {:ok, "cash"}
      {:ok, "hotel_credit"} -> {:ok, "hotel_credit"}
      _ -> :error
    end
  end

  defp fetch_present(raw, key) do
    case fetch(raw, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_string(raw, key) do
    case fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp optional_string(raw, key) do
    case fetch(raw, key) do
      {:ok, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp fetch(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(raw, String.to_atom(key))
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  # Results

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, extra)
  end
end
