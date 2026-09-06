defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and reports the outcome of each one.

  Each operation runs in its own transaction. `operation_id` makes operations
  durably idempotent: the first submission of an identifier is processed
  normally and its result is remembered; an identical retry replays the stored
  result without touching domain state, while a different payload for the same
  identifier is rejected with `operation_id_conflict`. Handled rejections leave
  domain state unchanged but still commit their idempotency record, so the
  record always commits together with the domain changes it describes. An
  unexpected exception rolls the operation back entirely, is not remembered,
  and aborts the batch.

  Cash and hotel credit fund the deposits of a group's active rooms in the
  rooms' original order; every funding, settlement, reduction, chargeback,
  and transfer is tracked as room allocations so the money keeps its identity.
  """

  alias Ecto.Changeset
  alias GroupStay.Groups
  alias GroupStay.Repo

  alias GroupStay.Schemas.{
    CreditEntitlement,
    CreditLot,
    Group,
    LedgerEntry,
    OperationRecord,
    Payment,
    Room,
    RoomAllocation
  }

  import Ecto.Query, only: [from: 2]

  @operation_types [
    "open_group",
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "apply_hotel_credit",
    "cancel_rooms",
    "reduce_cash_payment",
    "charge_back_payment",
    "transfer_deposit"
  ]

  @group_addressed_types [
    "open_group",
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "apply_hotel_credit",
    "cancel_rooms"
  ]

  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_numerator 20
  @credit_bonus_numerator 110
  @credit_validity_days 365

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Returns the remembered result for `operation_id`, or `:error` when this
  release never received an operation with that identifier.
  """
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, decode_result(record.result)}
    end
  end

  defp apply_operation(raw) do
    case Repo.transaction(fn -> run(raw) end) do
      {:ok, result} -> result
      {:error, {:idempotency_race, operation_id}} -> resolve_race(raw, operation_id)
      {:error, result} -> result
    end
  end

  defp run(raw) when is_map(raw) do
    operation_id = raw["operation_id"]

    case durable_record(operation_id) do
      nil -> process(raw, operation_id)
      record -> replay(record, raw, operation_id)
    end
  end

  defp run(_raw), do: reject(nil, "invalid_operation")

  # The record is committed in the same transaction as the domain changes, so
  # committing the record and applying the operation once are a single fact.
  defp process(raw, operation_id) do
    result = apply_validated(raw)

    case remember(operation_id, raw, result) do
      :ok -> result
      :untracked -> result
      {:error, :race} -> Repo.rollback({:idempotency_race, operation_id})
    end
  end

  defp apply_validated(raw) do
    operation_id = raw["operation_id"]

    with :ok <- ensure_identifier(operation_id),
         {:ok, type} <- ensure_operation_type(raw["type"]),
         {:ok, occurred_on, group_ref} <- ensure_common_fields(type, raw) do
      dispatch(type, raw, operation_id, occurred_on, group_ref)
    else
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp durable_record(operation_id) when is_binary(operation_id) and operation_id != "",
    do: Repo.get_by(OperationRecord, operation_id: operation_id)

  defp durable_record(_operation_id), do: nil

  defp replay(record, raw, operation_id) do
    if record.payload == canonical_json(raw),
      do: decode_result(record.result),
      else: reject(operation_id, "operation_id_conflict")
  end

  defp remember(operation_id, _raw, _result)
       when not is_binary(operation_id) or operation_id == "",
       do: :untracked

  defp remember(operation_id, raw, result) do
    changeset =
      %OperationRecord{}
      |> Changeset.change(%{
        operation_id: operation_id,
        type: operation_type(raw),
        payload: canonical_json(raw),
        result: encode_result(result)
      })
      |> Changeset.unique_constraint(:operation_id)

    case Repo.insert(changeset) do
      {:ok, _record} ->
        :ok

      {:error, %Changeset{} = changeset} ->
        if unique_violation?(changeset) do
          # A concurrent submission of the same identifier won the race; this
          # transaction is rolled back so its domain changes never land.
          {:error, :race}
        else
          raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end
  end

  # A concurrent first submission committed the same operation_id before this
  # transaction could. Its record is now authoritative: identical payloads
  # replay its stored result, anything else is a conflict.
  defp resolve_race(raw, operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> reject(operation_id, "operation_id_conflict")
      record -> replay(record, raw, operation_id)
    end
  end

  defp operation_type(raw) do
    case raw["type"] do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Canonical JSON encoding: object key order is irrelevant, so keys are
  # emitted in sorted order, while array order and all values are preserved.
  defp canonical_json(value) when is_map(value) do
    body =
      value
      |> Enum.map(fn {key, value} -> {Jason.encode!(key), canonical_json(value)} end)
      |> Enum.sort_by(fn {encoded_key, _encoded_value} -> encoded_key end)
      |> Enum.map_join(",", fn {encoded_key, encoded_value} ->
        encoded_key <> ":" <> encoded_value
      end)

    "{" <> body <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp encode_result(result), do: Jason.encode!(result)

  defp decode_result(result), do: Jason.decode!(result)

  defp ensure_common_fields(type, raw) when type in @group_addressed_types do
    with {:ok, occurred_on} <- fetch_occurred_on(raw["occurred_on"]),
         :ok <- ensure_identifier(raw["group_id"]) do
      {:ok, occurred_on, raw["group_id"]}
    end
  end

  defp ensure_common_fields("transfer_deposit", raw) do
    with :ok <- ensure_identifier(raw["source_group_id"]),
         :ok <- ensure_identifier(raw["destination_group_id"]) do
      {:ok, nil, nil}
    end
  end

  defp ensure_common_fields(_type, raw) do
    with :ok <- ensure_identifier(raw["payment_operation_id"]) do
      {:ok, nil, nil}
    end
  end

  defp dispatch("open_group", raw, operation_id, occurred_on, group_ref) do
    with :ok <- ensure_absent(group_ref),
         :ok <- ensure_identifier(raw["guest_id"]),
         :ok <- ensure_identifier(raw["property_id"]),
         {:ok, arrival_on, departure_on} <- parse_stay(raw),
         {:ok, rooms} <- parse_rooms(raw["rooms"]),
         :ok <- ensure_rate_plan(raw["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = lodging_total_cents(nights, rooms)
      deposit_due = deposit_due_cents(raw["rate_plan"], nights, rooms)

      {:ok, group} =
        Repo.insert(%Group{
          group_id: group_ref,
          guest_id: raw["guest_id"],
          property_id: raw["property_id"],
          arrival_on: arrival_on,
          departure_on: departure_on,
          booked_on: occurred_on,
          rate_plan: raw["rate_plan"],
          policy_version: Groups.policy_version(raw["rate_plan"], occurred_on),
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0
        })

      rooms
      |> Enum.with_index(1)
      |> Enum.each(fn {{room_id, nightly_rate_cents}, position} ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room_id,
          nightly_rate_cents: nightly_rate_cents,
          position: position,
          status: "active",
          lodging_cents: nights * nightly_rate_cents,
          deposit_due_cents: room_deposit_due_cents(raw["rate_plan"], nights, nightly_rate_cents),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

      applied(operation_id, %{
        group_id: group_ref,
        deposit_due_cents: deposit_due,
        revision: group.revision
      })
    else
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("record_cash_payment", raw, operation_id, occurred_on, group_ref) do
    amount = raw["amount_cents"]

    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         :ok <- ensure_amount(amount),
         :ok <- ensure_within_outstanding(group, amount) do
      allocate_funding(group, active_rooms(group), amount, "cash", operation_id, nil)

      Repo.insert!(%Payment{
        operation_id: operation_id,
        group_id: group.id,
        recorded_cents: amount,
        held_cents: amount
      })

      {:ok, updated} =
        group
        |> Changeset.change(
          deposit_paid_cents: group.deposit_paid_cents + amount,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: group.revision + 1
        )
        |> Repo.update()

      insert_ledger_entry(group, operation_id, occurred_on, "payment", amount)

      applied(operation_id, %{
        group_id: group_ref,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("reschedule_group", raw, operation_id, occurred_on, group_ref) do
    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_stay_date(raw["new_arrival_on"]),
         :ok <- ensure_after_occurrence(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      {:ok, updated} =
        group
        |> Changeset.change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update()

      applied(operation_id, %{
        group_id: group_ref,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        policy_version: updated.policy_version,
        refundable_until: iso_date(Groups.refundable_until(updated)),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("cancel_group", raw, operation_id, occurred_on, group_ref) do
    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- ensure_refund_method(raw["refund_method"]),
         :ok <- ensure_refund_method_available(refund_method, group, occurred_on) do
      settlement =
        settle_rooms(group, active_rooms(group), occurred_on, refund_method, operation_id)

      applied(operation_id, %{
        group_id: group_ref,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: settlement.group.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("cancel_rooms", raw, operation_id, occurred_on, group_ref) do
    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- ensure_refund_method(raw["refund_method"]),
         {:ok, rooms} <- select_rooms(group, raw["room_ids"]),
         :ok <- ensure_refund_method_available(refund_method, group, occurred_on) do
      settlement = settle_rooms(group, rooms, occurred_on, refund_method, operation_id)

      applied(operation_id, %{
        group_id: group_ref,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: settlement.group.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("apply_hotel_credit", raw, operation_id, occurred_on, group_ref) do
    amount = raw["amount_cents"]

    with {:ok, group} <- fetch_group(group_ref),
         :ok <- ensure_revision(raw, group),
         :ok <- ensure_active(group),
         :ok <- ensure_amount(amount),
         :ok <- ensure_within_outstanding(group, amount),
         :ok <- ensure_sufficient_credit(group, amount, occurred_on) do
      consume_credit_lots(group, active_rooms(group), amount, operation_id, occurred_on)

      {:ok, updated} =
        group
        |> Changeset.change(
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: group.revision + 1
        )
        |> Repo.update()

      applied(operation_id, %{
        group_id: group_ref,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("reduce_cash_payment", raw, operation_id, _occurred_on, _group_ref) do
    payment_ref = raw["payment_operation_id"]
    amount = raw["amount_cents"]

    with {:ok, record} <- fetch_operation_record(payment_ref),
         {:ok, group} <- resolve_payment_group(record),
         :ok <- ensure_revision(raw, group),
         {:ok, payment} <- ensure_reducible_payment(record),
         :ok <- ensure_amount(amount),
         :ok <- ensure_within_held(payment, amount) do
      deltas = remove_held_cash(payment, amount, :partial)

      payment
      |> Changeset.change(
        held_cents: payment.held_cents - amount,
        reduced_cents: payment.reduced_cents + amount
      )
      |> Repo.update!()

      updated =
        apply_removal_deltas(group, deltas, cash_reduced_cents: group.cash_reduced_cents + amount)

      insert_ledger_entry(group, operation_id, operation_date(raw), "reduction", amount)

      applied(operation_id, %{
        payment_operation_id: payment_ref,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("charge_back_payment", raw, operation_id, _occurred_on, _group_ref) do
    payment_ref = raw["payment_operation_id"]

    with {:ok, record} <- fetch_operation_record(payment_ref),
         {:ok, group} <- resolve_payment_group(record),
         :ok <- ensure_revision(raw, group),
         {:ok, payment} <- ensure_chargeable_payment(record) do
      held = payment.held_cents
      refunded = payment.refunded_cents
      retained = payment.retained_cents
      converted = payment.converted_cents
      charged_back = held + refunded + retained + converted

      deltas = remove_held_cash(payment, held, :all)
      revoke_entitlements(payment)

      payment
      |> Changeset.change(
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: payment.charged_back_cents + charged_back
      )
      |> Repo.update!()

      updated =
        apply_removal_deltas(
          group,
          deltas,
          refunded_cents: group.refunded_cents - refunded,
          retained_cents: group.retained_cents - retained,
          converted_to_credit_cents: group.converted_to_credit_cents - converted,
          cash_charged_back_cents: group.cash_charged_back_cents + charged_back
        )

      insert_ledger_entry(group, operation_id, operation_date(raw), "chargeback", charged_back)

      applied(operation_id, %{
        payment_operation_id: payment_ref,
        group_id: group.group_id,
        charged_back_cents: charged_back,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated),
        revision: updated.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  defp dispatch("transfer_deposit", raw, operation_id, _occurred_on, _group_ref) do
    source_ref = raw["source_group_id"]
    destination_ref = raw["destination_group_id"]
    amount = raw["amount_cents"]

    with {:ok, source} <- fetch_transfer_group(source_ref),
         {:ok, destination} <- fetch_transfer_group(destination_ref),
         :ok <- ensure_transfer_revision(raw["expected_revision"], source),
         :ok <-
           ensure_transfer_revision(raw["destination_expected_revision"], destination),
         :ok <- ensure_transfer_pair(source, destination),
         :ok <- ensure_transfer_active(source, destination),
         :ok <- ensure_amount(amount),
         :ok <- ensure_transfer_funding(source, amount),
         :ok <- ensure_transfer_capacity(destination, amount) do
      units = draw_funding(source, amount)

      {cash_drawn, credit_drawn} = split_drawn_kinds(units)

      place_funding(destination, units)
      mark_transferred_payments(units)

      {:ok, updated_source} =
        source
        |> Changeset.change(
          deposit_paid_cents: source.deposit_paid_cents - amount,
          cash_paid_cents: source.cash_paid_cents - cash_drawn,
          credit_paid_cents: source.credit_paid_cents - credit_drawn,
          revision: source.revision + 1
        )
        |> Repo.update()

      {:ok, updated_destination} =
        destination
        |> Changeset.change(
          deposit_paid_cents: destination.deposit_paid_cents + amount,
          cash_paid_cents: destination.cash_paid_cents + cash_drawn,
          credit_paid_cents: destination.credit_paid_cents + credit_drawn,
          revision: destination.revision + 1
        )
        |> Repo.update()

      applied(operation_id, %{
        source_group_id: source_ref,
        destination_group_id: destination_ref,
        amount_cents: amount,
        source_outstanding_deposit_cents: Groups.outstanding_deposit_cents(updated_source),
        destination_outstanding_deposit_cents:
          Groups.outstanding_deposit_cents(updated_destination),
        source_revision: updated_source.revision,
        destination_revision: updated_destination.revision
      })
    else
      {:error, code, extras} -> reject(operation_id, code, extras)
      {:error, code} -> reject(operation_id, code)
    end
  end

  ## Deposit transfers

  defp fetch_transfer_group(group_ref) do
    case Repo.get_by(Group, group_id: group_ref) do
      nil -> {:error, "group_not_found", %{group_id: group_ref}}
      group -> {:ok, group}
    end
  end

  defp ensure_transfer_revision(nil, _group), do: :ok

  defp ensure_transfer_revision(expected, group) do
    if expected != group.revision do
      {:error, "stale_revision",
       %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}
    else
      :ok
    end
  end

  defp ensure_transfer_pair(%Group{id: id}, %Group{id: id}), do: {:error, "invalid_transfer"}
  defp ensure_transfer_pair(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok
  defp ensure_transfer_pair(_source, _destination), do: {:error, "invalid_transfer"}

  defp ensure_transfer_active(source, destination) do
    cond do
      source.status != "active" ->
        {:error, "group_not_active", %{group_id: source.group_id}}

      destination.status != "active" ->
        {:error, "group_not_active", %{group_id: destination.group_id}}

      true ->
        :ok
    end
  end

  defp ensure_transfer_funding(%Group{} = source, amount) do
    held = source.cash_paid_cents + source.credit_paid_cents

    if amount <= held, do: :ok, else: {:error, "transfer_exceeds_held_funding"}
  end

  defp ensure_transfer_capacity(%Group{} = destination, amount) do
    if amount <= Groups.outstanding_deposit_cents(destination),
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  # Draws `amount` from the source's active-room allocations in reverse
  # allocation order, regardless of funding kind. Partially drawn allocations
  # keep their remaining amount in place; every drawn unit keeps the
  # provenance of the allocation it came from.
  defp draw_funding(source, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^source.id,
          order_by: [desc: a.position]
      )

    {units, _remaining} =
      Enum.reduce(allocations, {[], amount}, fn allocation, {units, to_draw} ->
        if to_draw <= 0 do
          {units, to_draw}
        else
          take = min(allocation.amount_cents, to_draw)

          if take == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            allocation
            |> Changeset.change(amount_cents: allocation.amount_cents - take)
            |> Repo.update!()
          end

          decrement_room_funding(allocation.room_id, allocation.kind, take)

          unit = %{
            kind: allocation.kind,
            amount_cents: take,
            operation_id: allocation.operation_id,
            credit_lot_id: allocation.credit_lot_id
          }

          {[unit | units], to_draw - take}
        end
      end)

    Enum.reverse(units)
  end

  defp split_drawn_kinds(units) do
    Enum.reduce(units, {0, 0}, fn unit, {cash, credit} ->
      if unit.kind == "cash",
        do: {cash + unit.amount_cents, credit},
        else: {cash, credit + unit.amount_cents}
    end)
  end

  # Fills the destination's active rooms in their original order with the
  # drawn units in the order they were drawn, splitting a unit across rooms
  # when a room's remaining capacity is smaller than the unit.
  defp place_funding(destination, units) do
    rooms = active_rooms(destination)
    start_position = next_position(destination)
    start_sequence = next_allocation_sequence()

    {updated_rooms, _units, _position, _sequence} =
      Enum.reduce(rooms, {[], units, start_position, start_sequence}, fn room,
                                                                         {rooms, units, position,
                                                                          sequence} ->
        {room, units, position, sequence} =
          place_units(destination, room, units, position, sequence)

        {[room | rooms], units, position, sequence}
      end)

    persist_room_totals(rooms, Enum.reverse(updated_rooms))
  end

  defp place_units(group, room, units, position, sequence) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

    if capacity <= 0 or units == [] do
      {room, units, position, sequence}
    else
      [unit | rest] = units
      take = min(unit.amount_cents, capacity)

      Repo.insert!(%RoomAllocation{
        group_id: group.id,
        room_id: room.id,
        kind: unit.kind,
        amount_cents: take,
        operation_id: unit.operation_id,
        credit_lot_id: unit.credit_lot_id,
        position: position,
        sequence: sequence
      })

      room =
        if unit.kind == "cash",
          do: %{room | cash_paid_cents: room.cash_paid_cents + take},
          else: %{room | credit_paid_cents: room.credit_paid_cents + take}

      units =
        if unit.amount_cents == take,
          do: rest,
          else: [%{unit | amount_cents: unit.amount_cents - take} | rest]

      place_units(group, room, units, position + 1, sequence + 1)
    end
  end

  # Once any funding from a cash payment has participated in a transfer, that
  # payment's statement reports where its held cash currently funds rooms.
  defp mark_transferred_payments(units) do
    units
    |> Enum.filter(&(&1.kind == "cash" and is_binary(&1.operation_id)))
    |> Enum.map(& &1.operation_id)
    |> Enum.uniq()
    |> Enum.each(fn operation_id ->
      case Repo.get_by(Payment, operation_id: operation_id) do
        nil ->
          :ok

        payment ->
          unless payment.transferred do
            payment
            |> Changeset.change(transferred: true)
            |> Repo.update!()
          end
      end
    end)
  end

  defp decrement_room_funding(room_id, "cash", amount) do
    room = Repo.get!(Room, room_id)

    room
    |> Changeset.change(cash_paid_cents: room.cash_paid_cents - amount)
    |> Repo.update!()
  end

  defp decrement_room_funding(room_id, "credit", amount) do
    room = Repo.get!(Room, room_id)

    room
    |> Changeset.change(credit_paid_cents: room.credit_paid_cents - amount)
    |> Repo.update!()
  end

  ## Room accounting

  defp active_rooms(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: r.position
    )
  end

  defp room_deposit_due_cents("advance_purchase", nights, nightly_rate_cents),
    do: nights * nightly_rate_cents

  defp room_deposit_due_cents("flexible", nights, nightly_rate_cents),
    do: div(nights * nightly_rate_cents * @flexible_deposit_numerator + 50, 100)

  # Fills `amount` of funding into the rooms' remaining deposit capacity, in
  # the rooms' original order, and records one allocation per room touched.
  defp allocate_funding(group, rooms, amount, kind, operation_id, lot_id) do
    next_position = next_position(group)
    next_sequence = next_allocation_sequence()

    {updated_rooms, allocations} = plan_fill(rooms, amount, kind)

    allocations
    |> Enum.with_index(0)
    |> Enum.each(fn {%{room_id: room_id, amount_cents: take}, index} ->
      Repo.insert!(%RoomAllocation{
        group_id: group.id,
        room_id: room_id,
        kind: kind,
        amount_cents: take,
        operation_id: operation_id,
        credit_lot_id: lot_id,
        position: next_position + index,
        sequence: next_sequence + index
      })
    end)

    persist_room_totals(rooms, updated_rooms)

    updated_rooms
  end

  # Pure planning pass: returns the rooms with their in-memory funding totals
  # bumped, plus the per-room amounts taken, without touching the database.
  defp plan_fill(rooms, amount, kind) do
    {updated_rooms, allocations, _remaining} =
      Enum.reduce(rooms, {[], [], amount}, fn room, {rooms, allocations, remaining} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        take = min(max(capacity, 0), remaining)

        if take > 0 do
          updated_room =
            if kind == "cash",
              do: %{room | cash_paid_cents: room.cash_paid_cents + take},
              else: %{room | credit_paid_cents: room.credit_paid_cents + take}

          {rooms ++ [updated_room], allocations ++ [%{room_id: room.id, amount_cents: take}],
           remaining - take}
        else
          {rooms ++ [room], allocations, remaining}
        end
      end)

    {updated_rooms, allocations}
  end

  defp persist_room_totals(rooms, updated_rooms) do
    original_by_id = Map.new(rooms, &{&1.id, &1})

    Enum.each(updated_rooms, fn room ->
      original = Map.get(original_by_id, room.id)

      if room.cash_paid_cents != original.cash_paid_cents or
           room.credit_paid_cents != original.credit_paid_cents do
        original
        |> Changeset.change(
          cash_paid_cents: room.cash_paid_cents,
          credit_paid_cents: room.credit_paid_cents
        )
        |> Repo.update!()
      end
    end)
  end

  defp next_position(group) do
    Repo.one(
      from a in RoomAllocation,
        where: a.group_id == ^group.id,
        select: fragment("COALESCE(MAX(?), 0)", a.position)
    ) + 1
  end

  # A creation counter that is comparable across groups, so a payment's held
  # allocations can be ordered globally after transfers spread them.
  defp next_allocation_sequence do
    Repo.one(
      from a in RoomAllocation,
        select: fragment("COALESCE(MAX(?), 0)", a.sequence)
    ) + 1
  end

  ## Settling rooms

  # Settles the given rooms' allocated cash and credit using the group's
  # policy, the chosen refund method, and the operation date. The rooms are
  # cancelled, their allocations are settled, and the group totals shrink to
  # the remaining active rooms.
  defp settle_rooms(group, rooms, occurred_on, refund_method, operation_id) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(from a in RoomAllocation, where: a.room_id in ^room_ids, order_by: a.position)

    cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))

    cash_total = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    credit_total = Enum.sum(Enum.map(credit_allocations, & &1.amount_cents))

    refundable = Groups.refundable?(group, occurred_on)

    {refunded, retained, converted, issued} =
      cond do
        not refundable -> {0, cash_total, 0, 0}
        refund_method == "hotel_credit" -> {0, 0, cash_total, credit_lot_amount(cash_total)}
        true -> {cash_total, 0, 0, 0}
      end

    settle_payment_dispositions(
      cash_allocations,
      settlement_disposition(refundable, refund_method)
    )

    if converted > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, @credit_validity_days),
          unrecovered_clawback_cents: 0
        })

      assign_entitlements(lot, ordered_cash_operations(cash_allocations))
    end

    if refundable, do: Enum.each(credit_allocations, &restore_credit_allocation/1)

    Repo.delete_all(from a in RoomAllocation, where: a.room_id in ^room_ids)

    Enum.each(rooms, fn room ->
      room
      |> Changeset.change(
        status: "cancelled",
        lodging_cents: 0,
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    lodging_delta = Enum.sum(Enum.map(rooms, & &1.lodging_cents))
    due_delta = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    active_remaining =
      Repo.one(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          select: count(r.id)
      )

    {:ok, updated} =
      group
      |> Changeset.change(
        lodging_total_cents: group.lodging_total_cents - lodging_delta,
        deposit_due_cents: group.deposit_due_cents - due_delta,
        deposit_paid_cents: group.deposit_paid_cents - cash_total - credit_total,
        cash_paid_cents: group.cash_paid_cents - cash_total,
        credit_paid_cents: group.credit_paid_cents - credit_total,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        converted_to_credit_cents: group.converted_to_credit_cents + converted,
        status: if(active_remaining == 0, do: "cancelled", else: group.status),
        revision: group.revision + 1
      )
      |> Repo.update()

    if refunded > 0,
      do: insert_ledger_entry(group, operation_id, occurred_on, "refund", refunded)

    if retained > 0,
      do: insert_ledger_entry(group, operation_id, occurred_on, "retention", retained)

    %{
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      group: updated
    }
  end

  defp settlement_disposition(true, "hotel_credit"), do: :converted_cents
  defp settlement_disposition(true, _refund_method), do: :refunded_cents
  defp settlement_disposition(false, _refund_method), do: :retained_cents

  defp settle_payment_dispositions(cash_allocations, disposition_field) do
    cash_allocations
    |> Enum.filter(& &1.operation_id)
    |> Enum.group_by(& &1.operation_id)
    |> Enum.each(fn {operation_id, allocations} ->
      amount = allocations |> Enum.map(& &1.amount_cents) |> Enum.sum()

      case Repo.get_by(Payment, operation_id: operation_id) do
        nil ->
          :ok

        payment ->
          payment
          |> Changeset.change([
            {disposition_field, Map.fetch!(payment, disposition_field) + amount},
            held_cents: payment.held_cents - amount
          ])
          |> Repo.update!()
      end
    end)
  end

  # The operations whose cash is being converted, in funding order: the
  # unattributed senior block first, then durable operations in the order
  # their allocations were filled.
  defp ordered_cash_operations(cash_allocations) do
    cash_allocations
    |> Enum.map(& &1.operation_id)
    |> Enum.uniq()
    |> Enum.map(fn operation_id ->
      amount =
        cash_allocations
        |> Enum.filter(&(&1.operation_id == operation_id))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      {operation_id, amount}
    end)
  end

  # Entitlements telescope to the issued lot: each payment owns the standard
  # bonus value of the settled cash through it, minus the bonus value through
  # the preceding payment, both rounded half-up.
  defp assign_entitlements(lot, ordered_operations) do
    {_cumulative, entitlements} =
      Enum.reduce(ordered_operations, {0, []}, fn {operation_id, amount},
                                                  {cumulative, entitlements} ->
        previous = credit_lot_amount(cumulative)
        cumulative = cumulative + amount
        current = credit_lot_amount(cumulative)

        entitlements =
          if operation_id && current - previous > 0,
            do: [{operation_id, current - previous} | entitlements],
            else: entitlements

        {cumulative, entitlements}
      end)

    Enum.each(entitlements, fn {operation_id, entitlement_cents} ->
      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: operation_id,
        entitlement_cents: entitlement_cents
      })
    end)
  end

  # Restores settled credit to its original lot. Returned credit first
  # extinguishes any unrecovered clawback on that lot; only the excess
  # becomes available again (and may already have expired).
  defp restore_credit_allocation(allocation) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorb = min(allocation.amount_cents, max(lot.unrecovered_clawback_cents, 0))

    lot
    |> Changeset.change(
      remaining_cents: lot.remaining_cents + allocation.amount_cents - absorb,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb
    )
    |> Repo.update!()
  end

  defp select_rooms(group, room_ids) when is_list(room_ids) do
    rooms = Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: r.position)

    active_room_ids =
      rooms |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id) |> MapSet.new()

    wanted = MapSet.new(room_ids)

    valid? =
      room_ids != [] and
        Enum.all?(room_ids, &is_binary/1) and
        MapSet.size(wanted) == length(room_ids) and
        Enum.all?(room_ids, &MapSet.member?(active_room_ids, &1))

    if valid?,
      do: {:ok, Enum.filter(rooms, &MapSet.member?(wanted, &1.room_id))},
      else: {:error, "invalid_rooms"}
  end

  defp select_rooms(_group, _room_ids), do: {:error, "invalid_rooms"}

  ## Credit consumption

  defp consume_credit_lots(group, rooms, amount, operation_id, occurred_on) do
    group.guest_id
    |> available_credit_lots(occurred_on)
    |> Enum.reduce_while({rooms, amount}, fn lot, {rooms, remaining} ->
      take = min(lot.remaining_cents, remaining)

      if take > 0 do
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents - take)
        |> Repo.update!()

        rooms = allocate_funding(group, rooms, take, "credit", operation_id, lot.id)
        remaining = remaining - take

        if remaining == 0,
          do: {:halt, {rooms, remaining}},
          else: {:cont, {rooms, remaining}}
      else
        {:cont, {rooms, remaining}}
      end
    end)
  end

  defp ensure_sufficient_credit(group, amount, occurred_on) do
    available =
      group.guest_id
      |> available_credit_lots(occurred_on)
      |> Enum.map(& &1.remaining_cents)
      |> Enum.sum()

    if available >= amount, do: :ok, else: {:error, "insufficient_credit"}
  end

  defp available_credit_lots(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  ## Payment corrections

  defp fetch_operation_record(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, "operation_not_found"}
      record -> {:ok, record}
    end
  end

  # The addressed group is the original payment's group. Records that are not
  # applied cash payments may still name a group, in which case the revision
  # contract applies before the payment itself is judged unusable.
  defp resolve_payment_group(record) do
    case Repo.get_by(Payment, operation_id: record.operation_id) do
      nil -> group_from_payload(record)
      payment -> {:ok, Repo.get!(Group, payment.group_id)}
    end
  end

  defp group_from_payload(record) do
    with {:ok, payload} <- Jason.decode(record.payload),
         group_ref when is_binary(group_ref) <- Map.get(payload, "group_id"),
         %Group{} = group <- Repo.get_by(Group, group_id: group_ref) do
      {:ok, group}
    else
      _other -> {:ok, nil}
    end
  end

  defp ensure_reducible_payment(record) do
    case Repo.get_by(Payment, operation_id: record.operation_id) do
      nil ->
        {:error, "payment_not_reducible"}

      payment ->
        if payment.held_cents > 0, do: {:ok, payment}, else: {:error, "payment_not_reducible"}
    end
  end

  defp ensure_chargeable_payment(record) do
    case Repo.get_by(Payment, operation_id: record.operation_id) do
      nil ->
        {:error, "payment_not_chargeable"}

      payment ->
        cond do
          payment.charged_back_cents > 0 -> {:error, "payment_not_chargeable"}
          payment.reduced_cents >= payment.recorded_cents -> {:error, "payment_not_chargeable"}
          true -> {:ok, payment}
        end
    end
  end

  defp ensure_within_held(payment, amount) do
    if amount <= payment.held_cents,
      do: :ok,
      else: {:error, "reduction_exceeds_held_cash"}
  end

  # Removes held cash of one payment wherever it currently funds rooms. A
  # partial removal takes allocations in reverse allocation order across all
  # groups and splits the last one it touches; `:all` removes every remaining
  # allocation of the payment. Returns the amount removed per group.
  defp remove_held_cash(payment, amount, mode) do
    {deltas, _remaining} =
      payment
      |> payment_allocations()
      |> Enum.reduce({%{}, amount}, fn allocation, {deltas, to_remove} ->
        cond do
          mode == :all ->
            delete_cash_allocation(allocation)

            {track_removal(deltas, allocation.group_id, allocation.amount_cents),
             to_remove - allocation.amount_cents}

          to_remove <= 0 ->
            {deltas, to_remove}

          allocation.amount_cents <= to_remove ->
            delete_cash_allocation(allocation)

            {track_removal(deltas, allocation.group_id, allocation.amount_cents),
             to_remove - allocation.amount_cents}

          true ->
            decrement_room_cash(allocation.room_id, to_remove)

            Repo.delete!(allocation)

            Repo.insert!(%RoomAllocation{
              group_id: allocation.group_id,
              room_id: allocation.room_id,
              kind: allocation.kind,
              amount_cents: allocation.amount_cents - to_remove,
              operation_id: allocation.operation_id,
              credit_lot_id: allocation.credit_lot_id,
              position: allocation.position,
              sequence: allocation.sequence
            })

            {track_removal(deltas, allocation.group_id, to_remove), 0}
        end
      end)

    deltas
  end

  defp delete_cash_allocation(allocation) do
    decrement_room_cash(allocation.room_id, allocation.amount_cents)
    Repo.delete!(allocation)
  end

  defp track_removal(deltas, group_id, amount),
    do: Map.update(deltas, group_id, amount, &(&1 + amount))

  # Every group whose state the removal changes reopens its outstanding
  # deposit and increments its revision; the addressed group always increments
  # its revision, even when none of the removed funding was held there.
  defp apply_removal_deltas(addressed_group, deltas, extra_addressed_changes) do
    [addressed_group.id]
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(deltas)))
    |> Enum.reduce(nil, fn group_id, updated ->
      changed = Repo.get!(Group, group_id)
      removed = Map.get(deltas, group_id, 0)

      changes = [
        deposit_paid_cents: changed.deposit_paid_cents - removed,
        cash_paid_cents: changed.cash_paid_cents - removed,
        revision: changed.revision + 1
      ]

      changes =
        if group_id == addressed_group.id,
          do: Keyword.merge(changes, extra_addressed_changes),
          else: changes

      {:ok, updated_group} = changed |> Changeset.change(changes) |> Repo.update()

      if group_id == addressed_group.id, do: updated_group, else: updated
    end)
  end

  defp payment_allocations(payment) do
    Repo.all(
      from a in RoomAllocation,
        where: a.operation_id == ^payment.operation_id and a.kind == "cash",
        order_by: [desc: a.sequence]
    )
  end

  defp decrement_room_cash(room_id, amount) do
    room = Repo.get!(Room, room_id)

    room
    |> Changeset.change(cash_paid_cents: room.cash_paid_cents - amount)
    |> Repo.update!()
  end

  # A clawback removes the payment's entitlement from the lot's remaining
  # balance first; whatever cannot be removed becomes that lot's unrecovered
  # clawback.
  defp revoke_entitlements(payment) do
    from(e in CreditEntitlement,
      where: e.payment_operation_id == ^payment.operation_id,
      preload: [:credit_lot]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = entitlement.credit_lot
      take = min(entitlement.entitlement_cents, max(lot.remaining_cents, 0))

      lot
      |> Changeset.change(
        remaining_cents: lot.remaining_cents - take,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + (entitlement.entitlement_cents - take)
      )
      |> Repo.update!()
    end)
  end

  ## Shared helpers

  defp ensure_refund_method(refund_method) when refund_method in [nil, "cash", "hotel_credit"],
    do: {:ok, refund_method || "cash"}

  defp ensure_refund_method(_refund_method), do: {:error, "invalid_operation"}

  defp ensure_refund_method_available("hotel_credit", group, occurred_on) do
    if Groups.refundable?(group, occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  defp ensure_refund_method_available(_refund_method, _group, _occurred_on), do: :ok

  defp credit_lot_amount(cash), do: round_half_up_to_cent(cash * @credit_bonus_numerator)

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp operation_date(raw) do
    case parse_date(raw["occurred_on"]) do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end

  defp insert_ledger_entry(group, operation_id, occurred_on, kind, amount) do
    Repo.insert!(%LedgerEntry{
      group_id: group.id,
      operation_id: operation_id,
      kind: kind,
      amount_cents: amount,
      occurred_on: occurred_on
    })
  end

  defp lodging_total_cents(nights, rooms),
    do: rooms |> Enum.map(fn {_room_id, rate} -> nights * rate end) |> Enum.sum()

  defp deposit_due_cents("flexible", nights, rooms) do
    rooms
    |> Enum.map(fn {_room_id, rate} ->
      round_half_up_to_cent(nights * rate * @flexible_deposit_numerator)
    end)
    |> Enum.sum()
  end

  defp deposit_due_cents("advance_purchase", nights, rooms),
    do: lodging_total_cents(nights, rooms)

  defp round_half_up_to_cent(amount), do: div(amount + 50, 100)

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp reject(operation_id, code, extras \\ %{}) do
    base = %{status: "rejected", code: code}

    base =
      if is_binary(operation_id), do: Map.put(base, :operation_id, operation_id), else: base

    Map.merge(base, extras)
  end

  defp ensure_identifier(value) when is_binary(value) and value != "", do: :ok
  defp ensure_identifier(_value), do: {:error, "invalid_operation"}

  defp ensure_operation_type(type) when type in @operation_types, do: {:ok, type}
  defp ensure_operation_type(_type), do: {:error, "invalid_operation"}

  defp fetch_occurred_on(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_stay(raw) do
    with {:ok, arrival_on} <- parse_stay_date(raw["arrival_on"]),
         {:ok, departure_on} <- parse_stay_date(raw["departure_on"]),
         :ok <- ensure_nights(arrival_on, departure_on) do
      {:ok, arrival_on, departure_on}
    end
  end

  defp parse_stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp ensure_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: {:error, "invalid_stay"}
  end

  defp ensure_after_occurrence(new_arrival_on, occurred_on) do
    if Date.diff(new_arrival_on, occurred_on) >= 1, do: :ok, else: {:error, "invalid_stay"}
  end

  defp parse_rooms(rooms) when is_list(rooms) do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.all?(parsed, &match?({:ok, _room}, &1)) do
      rooms = Enum.map(parsed, fn {:ok, room} -> room end)
      room_ids = Enum.map(rooms, fn {room_id, _rate} -> room_id end)

      if rooms != [] and Enum.uniq(room_ids) == room_ids,
        do: {:ok, rooms},
        else: {:error, "invalid_rooms"}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp parse_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp parse_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0,
       do: {:ok, {room_id, rate}}

  defp parse_room(_room), do: :error

  defp ensure_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp ensure_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp ensure_absent(group_ref) do
    if Repo.get_by(Group, group_id: group_ref) == nil,
      do: :ok,
      else: {:error, "group_already_exists"}
  end

  defp fetch_group(group_ref) do
    case Repo.get_by(Group, group_id: group_ref) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp ensure_revision(_raw, nil), do: :ok

  defp ensure_revision(raw, group) do
    case raw do
      %{"expected_revision" => expected} when expected != group.revision ->
        {:error, "stale_revision",
         %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}

      _other ->
        :ok
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, "group_not_active"}

  defp ensure_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp ensure_amount(_amount), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount) do
    if amount <= Groups.outstanding_deposit_cents(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end
end
