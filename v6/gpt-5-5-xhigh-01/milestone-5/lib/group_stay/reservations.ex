defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditEntitlement
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.LedgerEntry
  alias GroupStay.Reservations.OperationRecord
  alias GroupStay.Reservations.Room
  alias GroupStay.Reservations.RoomAllocation

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @record_cash_payment "record_cash_payment"
  @apply_hotel_credit "apply_hotel_credit"
  @transfer_deposit "transfer_deposit"
  @cash_payment "cash_payment"
  @cash_refund "cash_refund"
  @cash_retention "cash_retention"
  @cash_credit_conversion "cash_credit_conversion"
  @cash_reduction "cash_reduction"
  @cash_held_chargeback "cash_held_chargeback"
  @cash_refund_chargeback "cash_refund_chargeback"
  @cash_retention_chargeback "cash_retention_chargeback"
  @cash_conversion_chargeback "cash_conversion_chargeback"
  @refund_cash "cash"
  @refund_hotel_credit "hotel_credit"
  @alloc_cash "cash"
  @alloc_credit "credit"
  @disp_held "held"
  @disp_refunded "refunded"
  @disp_retained "retained"
  @disp_converted "converted"
  @disp_reduced "reduced"
  @disp_charged_back "charged_back"
  @disp_applied "applied"
  @disp_restored "restored"
  @disp_consumed "consumed"
  @disp_transferred "transferred"

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation_transaction/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    {:ok, group} =
      Repo.transaction(fn ->
        case fetch_group(group_id) do
          nil ->
            nil

          group ->
            group
            |> ensure_group_accounting!()
            |> sync_group_totals!()
            |> preload_rooms()
        end
      end)

    group
  end

  def get_group(_group_id), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{result_json: result_json} when is_binary(result_json) ->
        Jason.decode!(result_json)

      _record ->
        nil
    end
  end

  def get_operation_result(_operation_id), do: nil

  def get_payment_reconciliation(payment_operation_id) when is_binary(payment_operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, _record, payment_result} <-
               fetch_payment_record(payment_operation_id, "payment_not_reconcilable") do
          original_group_id = payment_result["group_id"]

          if group = fetch_group(original_group_id) do
            group
            |> ensure_group_accounting!()
            |> sync_group_totals!()
          end

          {:ok, payment_reconciliation_data(payment_operation_id, payment_result)}
        end
      end)

    case result do
      {:ok, data} -> {:ok, data}
      {:error, %{code: "operation_not_found"}} -> :not_found
      {:error, %{code: "payment_not_reconcilable"}} -> :not_reconcilable
    end
  end

  def get_payment_reconciliation(_payment_operation_id), do: :not_found

  def group_data(%Group{} = group) do
    room_sums = room_allocation_sums(Enum.map(group.rooms, & &1.id))

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until_data(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_data(&1, room_sums)),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents(group),
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: credit_paid_cents(group),
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger_totals(on_param \\ nil) do
    ensure_all_active_group_accounting!()

    as_of = as_of_date(on_param)

    totals =
      LedgerEntry
      |> group_by([entry], entry.entry_type)
      |> select([entry], {entry.entry_type, sum(entry.amount_cents)})
      |> Repo.all()
      |> Map.new(fn {entry_type, amount} -> {entry_type, amount || 0} end)

    payment_cents = Map.get(totals, @cash_payment, 0)

    refunded_cents =
      Map.get(totals, @cash_refund, 0) - Map.get(totals, @cash_refund_chargeback, 0)

    retained_cents =
      Map.get(totals, @cash_retention, 0) - Map.get(totals, @cash_retention_chargeback, 0)

    converted_cents =
      Map.get(totals, @cash_credit_conversion, 0) -
        Map.get(totals, @cash_conversion_chargeback, 0)

    reduced_cents = Map.get(totals, @cash_reduction, 0)

    charged_back_cents =
      Map.get(totals, @cash_held_chargeback, 0) +
        Map.get(totals, @cash_refund_chargeback, 0) +
        Map.get(totals, @cash_retention_chargeback, 0) +
        Map.get(totals, @cash_conversion_chargeback, 0)

    held_cents =
      max(
        payment_cents - refunded_cents - retained_cents - converted_cents - reduced_cents -
          charged_back_cents,
        0
      )

    %{
      cash_held_cents: held_cents,
      cash_refunded_cents: refunded_cents,
      cash_retained_cents: retained_cents,
      cash_converted_to_credit_cents: converted_cents,
      cash_reduced_cents: reduced_cents,
      cash_charged_back_cents: charged_back_cents,
      credit_liability_cents: credit_liability_cents(as_of),
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  def guest_credit_data(guest_id, on_param \\ nil) when is_binary(guest_id) do
    ensure_all_active_group_accounting!()

    as_of = as_of_date(on_param)
    lots = available_credit_lots(guest_id, as_of)
    available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    %{
      guest_id: guest_id,
      available_cents: available_cents,
      lots: Enum.map(lots, &credit_lot_data/1)
    }
  end

  defp apply_operation_transaction(operation) do
    case operation_identifier(operation) do
      {:ok, operation_id} -> apply_idempotent_operation(operation_id, operation)
      :error -> apply_unrecorded_operation(operation)
    end
  end

  defp apply_idempotent_operation(operation_id, operation) do
    payload_json = canonical_json(operation)
    operation_type = operation_type(operation)

    case Repo.transaction(fn ->
           case insert_operation_record(operation_id, operation_type, payload_json) do
             {:ok, operation_record} ->
               result = apply_recorded_operation(operation, operation_record)

               operation_record
               |> OperationRecord.result_changeset(%{result_json: Jason.encode!(result)})
               |> Repo.update!()

               result

             {:duplicate, operation_record} ->
               idempotent_result(operation_record, operation_id, payload_json)
           end
         end) do
      {:ok, result} -> result
    end
  end

  defp apply_unrecorded_operation(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation, nil) do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_recorded_operation(operation, operation_record) do
    case apply_operation(operation, operation_record.id) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp insert_operation_record(operation_id, operation_type, payload_json) do
    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: operation_type,
      payload_json: payload_json
    })
    |> Repo.insert()
    |> case do
      {:ok, operation_record} ->
        {:ok, operation_record}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :operation_id) do
          {:duplicate, Repo.get_by!(OperationRecord, operation_id: operation_id)}
        else
          raise "failed to record operation #{operation_id}: #{inspect(changeset.errors)}"
        end
    end
  end

  defp idempotent_result(operation_record, operation_id, payload_json) do
    if operation_record.payload_json == payload_json do
      stored_result!(operation_record)
    else
      %{
        operation_id: operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      }
    end
  end

  defp stored_result!(%OperationRecord{result_json: result_json}) when is_binary(result_json) do
    Jason.decode!(result_json)
  end

  defp stored_result!(%OperationRecord{operation_id: operation_id}) do
    raise "operation #{operation_id} has no stored result"
  end

  defp operation_identifier(operation) when is_map(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) and operation_id != "" -> {:ok, operation_id}
      _operation_id -> :error
    end
  end

  defp operation_identifier(_operation), do: :error

  defp operation_type(operation) when is_map(operation) do
    case operation["type"] do
      type when is_binary(type) -> type
      _type -> nil
    end
  end

  defp operation_type(_operation), do: nil

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, nested_value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(values) when is_list(values) do
    values
    |> Enum.map(&canonical_json/1)
    |> Enum.join(",")
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp apply_operation(operation, operation_record_id) do
    with {:ok, metadata} <- parse_common(operation, operation_record_id) do
      case metadata.type do
        "open_group" -> open_group(metadata)
        @record_cash_payment -> record_cash_payment(metadata)
        @apply_hotel_credit -> apply_hotel_credit(metadata)
        "reschedule_group" -> reschedule_group(metadata)
        "cancel_group" -> cancel_group(metadata)
        "cancel_rooms" -> cancel_rooms(metadata)
        "reduce_cash_payment" -> reduce_cash_payment(metadata)
        "charge_back_payment" -> charge_back_payment(metadata)
        @transfer_deposit -> transfer_deposit(metadata)
        _type -> reject(metadata, "invalid_operation")
      end
    end
  end

  defp parse_common(operation, operation_record_id) when is_map(operation) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    with true <- present_string?(operation_id),
         true <- present_string?(type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok,
       %{
         operation: operation,
         operation_id: operation_id,
         operation_record_id: operation_record_id,
         type: type,
         occurred_on: occurred_on
       }}
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp parse_common(operation, _operation_record_id), do: reject(operation, "invalid_operation")

  defp open_group(%{operation: operation} = metadata) do
    with :ok <- require_open_identifiers(operation, metadata),
         :ok <- ensure_group_unique(operation["group_id"], metadata),
         {:ok, arrival_on, departure_on, nights} <- parse_stay_dates(operation, metadata),
         :ok <- validate_rate_plan(operation["rate_plan"], metadata),
         {:ok, rooms} <- validate_rooms(operation["rooms"], metadata) do
      rooms = rooms_with_accounting(rooms, nights, operation["rate_plan"])
      lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2))
      deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))

      group =
        %Group{}
        |> Group.changeset(%{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: metadata.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version_for(operation["rate_plan"], metadata.occurred_on),
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1
        })
        |> Repo.insert()

      case group do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            %Room{}
            |> Room.changeset(%{
              group_id: group.id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: room.position,
              status: @active,
              lodging_total_cents: room.lodging_total_cents,
              deposit_due_cents: room.deposit_due_cents
            })
            |> Repo.insert!()
          end)

          apply_result(metadata, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })

        {:error, _changeset} ->
          reject(metadata, "group_already_exists")
      end
    end
  end

  defp record_cash_payment(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         :ok <- ensure_payment_within_outstanding(group, amount_cents, metadata) do
      insert_ledger_entry!(group, metadata, @cash_payment, amount_cents)
      allocate_cash_to_rooms!(group, metadata, amount_cents)

      group = sync_group_totals!(group, %{revision: group.revision + 1})

      apply_result(metadata, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp apply_hotel_credit(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         :ok <- ensure_payment_within_outstanding(group, amount_cents, metadata),
         {:ok, consumed_lots} <- consume_credit_lots(group, amount_cents, metadata) do
      Enum.each(consumed_lots, fn {lot, consumed_cents} ->
        insert_credit_application!(group, lot, metadata, consumed_cents)
        allocate_credit_to_rooms!(group, lot, metadata, consumed_cents)
      end)

      group = sync_group_totals!(group, %{revision: group.revision + 1})

      apply_result(metadata, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp reschedule_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, new_arrival_on} <- parse_reschedule_arrival(metadata) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      apply_result(metadata, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: policy_version(group),
        refundable_until: refundable_until_data(group),
        revision: group.revision
      })
    end
  end

  defp cancel_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, refund_method} <- refund_method(metadata),
         :ok <-
           ensure_refund_method_available(group, metadata.occurred_on, refund_method, metadata) do
      active_rooms = active_rooms(group.id)

      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms!(group, active_rooms, metadata, refund_method)

      cancel_rooms!(active_rooms)
      group = sync_group_totals!(group, %{status: @cancelled, revision: group.revision + 1})

      apply_result(metadata, %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      })
    end
  end

  defp cancel_rooms(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, refund_method} <- refund_method(metadata),
         :ok <-
           ensure_refund_method_available(group, metadata.occurred_on, refund_method, metadata),
         {:ok, rooms} <- cancellable_rooms(group, metadata) do
      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms!(group, rooms, metadata, refund_method)

      cancelled_room_ids = Enum.map(rooms, & &1.room_id)
      cancel_rooms!(rooms)

      new_status =
        if active_room_count(group.id) == 0 do
          @cancelled
        else
          @active
        end

      group = sync_group_totals!(group, %{status: new_status, revision: group.revision + 1})

      apply_result(metadata, %{
        group_id: group.group_id,
        cancelled_room_ids: cancelled_room_ids,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      })
    end
  end

  defp transfer_deposit(metadata) do
    with {:ok, source_group} <- fetch_transfer_group(metadata, "source_group_id"),
         {:ok, destination_group} <- fetch_transfer_group(metadata, "destination_group_id"),
         {:ok, source_group} <- ensure_revision(source_group, metadata, "expected_revision"),
         {:ok, destination_group} <-
           ensure_revision(destination_group, metadata, "destination_expected_revision"),
         :ok <- ensure_valid_transfer_groups(source_group, destination_group, metadata),
         :ok <- ensure_transfer_active(source_group, metadata),
         :ok <- ensure_transfer_active(destination_group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         {:ok, source_allocations} <-
           transferable_allocations(source_group, amount_cents, metadata),
         :ok <-
           ensure_transfer_within_destination_outstanding(
             destination_group,
             amount_cents,
             metadata
           ) do
      amount_cents
      |> draw_transfer_units!(source_allocations)
      |> allocate_transfer_units_to_destination!(destination_group)

      source_group = sync_group_totals!(source_group, %{revision: source_group.revision + 1})

      destination_group =
        sync_group_totals!(destination_group, %{revision: destination_group.revision + 1})

      apply_result(metadata, %{
        source_group_id: source_group.group_id,
        destination_group_id: destination_group.group_id,
        amount_cents: amount_cents,
        source_outstanding_deposit_cents: outstanding_deposit_cents(source_group),
        destination_outstanding_deposit_cents: outstanding_deposit_cents(destination_group),
        source_revision: source_group.revision,
        destination_revision: destination_group.revision
      })
    end
  end

  defp reduce_cash_payment(metadata) do
    with {:ok, payment_operation_id} <- payment_operation_id(metadata),
         {:ok, _record, payment_result} <-
           fetch_payment_record(payment_operation_id, "payment_not_reducible", metadata),
         {:ok, group} <- fetch_payment_group_for_update(payment_result, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         {:ok, _held_cents} <-
           reducible_held_cash(payment_operation_id, amount_cents, metadata) do
      changed_group_ids = reduce_cash_allocations!(payment_operation_id, amount_cents)
      insert_ledger_entry!(group, metadata, @cash_reduction, amount_cents)

      group =
        group
        |> sync_groups_after_funding_change!(changed_group_ids)
        |> Map.fetch!(group.id)

      apply_result(metadata, %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp charge_back_payment(metadata) do
    with {:ok, payment_operation_id} <- payment_operation_id(metadata),
         {:ok, _record, payment_result} <-
           fetch_payment_record(payment_operation_id, "payment_not_chargeable", metadata),
         {:ok, group} <- fetch_payment_group_for_update(payment_result, metadata),
         {:ok, disposition} <-
           chargeable_payment_disposition(payment_operation_id, payment_result, metadata) do
      held_allocations = held_cash_allocations_for_payment(payment_operation_id)

      refunded_allocations =
        payment_cash_allocations_for_disposition(payment_operation_id, @disp_refunded)

      retained_allocations =
        payment_cash_allocations_for_disposition(payment_operation_id, @disp_retained)

      converted_allocations =
        payment_cash_allocations_for_disposition(payment_operation_id, @disp_converted)

      held_cents = reclassify_allocation_set!(held_allocations, @disp_charged_back)

      refunded_cents = reclassify_allocation_set!(refunded_allocations, @disp_charged_back)

      retained_cents = reclassify_allocation_set!(retained_allocations, @disp_charged_back)

      converted_cents = reclassify_allocation_set!(converted_allocations, @disp_charged_back)

      changed_group_ids =
        [held_allocations, refunded_allocations, retained_allocations, converted_allocations]
        |> List.flatten()
        |> Enum.map(& &1.group_id)

      insert_ledger_entry!(group, metadata, @cash_held_chargeback, held_cents)
      insert_ledger_entry!(group, metadata, @cash_refund_chargeback, refunded_cents)
      insert_ledger_entry!(group, metadata, @cash_retention_chargeback, retained_cents)
      insert_ledger_entry!(group, metadata, @cash_conversion_chargeback, converted_cents)
      revoke_credit_entitlements!(payment_operation_id)

      group =
        group
        |> sync_groups_after_funding_change!(changed_group_ids)
        |> Map.fetch!(group.id)

      apply_result(metadata, %{
        payment_operation_id: payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: disposition.chargeable_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp require_open_identifiers(operation, metadata) do
    required_fields = ["group_id", "guest_id", "property_id"]

    if Enum.all?(required_fields, &present_string?(operation[&1])) do
      :ok
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_group_unique(group_id, metadata) do
    if fetch_group(group_id) do
      reject(metadata, "group_already_exists")
    else
      :ok
    end
  end

  defp parse_stay_dates(operation, metadata) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp validate_rate_plan(rate_plan, _metadata) when rate_plan in [@flexible, @advance_purchase],
    do: :ok

  defp validate_rate_plan(_rate_plan, metadata), do: reject(metadata, "invalid_rate_plan")

  defp validate_rooms(rooms, metadata) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {room, position},
                                                     {:ok, valid_rooms, room_ids} ->
      case validate_room(room, position, room_ids) do
        {:ok, valid_room} ->
          {:cont, {:ok, [valid_room | valid_rooms], MapSet.put(room_ids, valid_room.room_id)}}

        :error ->
          {:halt, reject(metadata, "invalid_rooms")}
      end
    end)
    |> case do
      {:ok, valid_rooms, _room_ids} -> {:ok, Enum.reverse(valid_rooms)}
      {:error, _result} = error -> error
    end
  end

  defp validate_rooms(_rooms, metadata), do: reject(metadata, "invalid_rooms")

  defp validate_room(room, position, room_ids) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate_cents = room["nightly_rate_cents"]

    cond do
      not present_string?(room_id) ->
        :error

      not (is_integer(nightly_rate_cents) and nightly_rate_cents >= 0) ->
        :error

      MapSet.member?(room_ids, room_id) ->
        :error

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    end
  end

  defp validate_room(_room, _position, _room_ids), do: :error

  defp rooms_with_accounting(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = room.nightly_rate_cents * nights
      deposit_due_cents = room_deposit_due_cents(lodging_total_cents, rate_plan)

      room
      |> Map.put(:lodging_total_cents, lodging_total_cents)
      |> Map.put(:deposit_due_cents, deposit_due_cents)
    end)
  end

  defp room_deposit_due_cents(lodging_total_cents, @flexible) do
    percentage_cents(lodging_total_cents, 20)
  end

  defp room_deposit_due_cents(lodging_total_cents, @advance_purchase), do: lodging_total_cents

  defp fetch_existing_group_for_update(%{operation: operation} = metadata) do
    group_id = operation["group_id"]

    if present_string?(group_id) do
      case fetch_group(group_id) do
        nil ->
          reject(metadata, "group_not_found")

        group ->
          group =
            group
            |> ensure_group_accounting!()
            |> sync_group_totals!()

          ensure_current_revision(group, metadata)
      end
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp fetch_payment_group_for_update(payment_result, metadata) do
    group_id = payment_result["group_id"]

    case fetch_group(group_id) do
      nil ->
        reject(metadata, "operation_not_found")

      group ->
        group =
          group
          |> ensure_group_accounting!()
          |> sync_group_totals!()

        ensure_current_revision(group, metadata)
    end
  end

  defp ensure_current_revision(group, metadata) do
    ensure_revision(group, metadata, "expected_revision")
  end

  defp ensure_revision(group, %{operation: operation} = metadata, revision_key) do
    case Map.fetch(operation, revision_key) do
      :error ->
        {:ok, group}

      {:ok, expected_revision} when expected_revision == group.revision ->
        {:ok, group}

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: metadata.operation_id,
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(%Group{status: @active}, _metadata), do: :ok
  defp ensure_active(%Group{}, metadata), do: reject(metadata, "group_not_active")

  defp fetch_transfer_group(%{operation: operation} = metadata, group_id_key) do
    group_id = operation[group_id_key]

    if present_string?(group_id) do
      case fetch_group(group_id) do
        nil ->
          reject(metadata, "group_not_found", %{group_id: group_id})

        group ->
          group =
            group
            |> ensure_group_accounting!()
            |> sync_group_totals!()

          {:ok, group}
      end
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_valid_transfer_groups(
         %Group{group_id: group_id},
         %Group{group_id: group_id},
         metadata
       ) do
    reject(metadata, "invalid_transfer")
  end

  defp ensure_valid_transfer_groups(
         %Group{guest_id: guest_id},
         %Group{guest_id: guest_id},
         _metadata
       ) do
    :ok
  end

  defp ensure_valid_transfer_groups(%Group{}, %Group{}, metadata) do
    reject(metadata, "invalid_transfer")
  end

  defp ensure_transfer_active(%Group{status: @active}, _metadata), do: :ok

  defp ensure_transfer_active(%Group{} = group, metadata) do
    reject(metadata, "group_not_active", %{group_id: group.group_id})
  end

  defp transferable_allocations(%Group{} = source_group, amount_cents, metadata) do
    allocations = transfer_source_allocations(source_group.id)
    held_cents = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))

    if held_cents < amount_cents do
      reject(metadata, "transfer_exceeds_held_funding")
    else
      {:ok, allocations}
    end
  end

  defp transfer_source_allocations(group_id) do
    RoomAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> where(
      [allocation, room],
      allocation.group_id == ^group_id and room.status == @active and
        ((allocation.allocation_type == @alloc_cash and allocation.disposition == @disp_held) or
           (allocation.allocation_type == @alloc_credit and
              allocation.disposition == @disp_applied))
    )
    |> order_by([allocation, _room], desc: allocation.id)
    |> Repo.all()
  end

  defp ensure_transfer_within_destination_outstanding(group, amount_cents, metadata) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      reject(metadata, "transfer_exceeds_outstanding")
    end
  end

  defp payment_amount(%{operation: operation} = metadata) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        reject(metadata, "invalid_amount")

      :error ->
        reject(metadata, "invalid_operation")
    end
  end

  defp ensure_payment_within_outstanding(group, amount_cents, metadata) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      reject(metadata, "payment_exceeds_outstanding")
    end
  end

  defp consume_credit_lots(group, amount_cents, metadata) do
    lots = available_credit_lots(group.guest_id, metadata.occurred_on)
    available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available_cents < amount_cents do
      reject(metadata, "insufficient_credit")
    else
      consumed_lots =
        lots
        |> take_credit(amount_cents)
        |> Enum.map(fn {lot, consumed_cents} ->
          lot =
            update_credit_lot!(lot, %{
              remaining_cents: lot.remaining_cents - consumed_cents
            })

          {lot, consumed_cents}
        end)

      {:ok, consumed_lots}
    end
  end

  defp take_credit(_lots, 0), do: []

  defp take_credit([lot | rest], amount_cents) do
    consumed_cents = min(lot.remaining_cents, amount_cents)
    [{lot, consumed_cents} | take_credit(rest, amount_cents - consumed_cents)]
  end

  defp parse_reschedule_arrival(%{operation: operation, occurred_on: occurred_on} = metadata) do
    with {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      {:ok, new_arrival_on}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp refund_method(%{operation: operation} = metadata) do
    case Map.get(operation, "refund_method", @refund_cash) do
      @refund_cash -> {:ok, @refund_cash}
      @refund_hotel_credit -> {:ok, @refund_hotel_credit}
      _other -> reject(metadata, "invalid_operation")
    end
  end

  defp ensure_refund_method_available(group, occurred_on, @refund_hotel_credit, metadata) do
    if refundable_cancellation?(group, occurred_on) do
      :ok
    else
      reject(metadata, "refund_method_not_available")
    end
  end

  defp ensure_refund_method_available(_group, _occurred_on, @refund_cash, _metadata), do: :ok

  defp cancellable_rooms(%Group{} = group, %{operation: operation} = metadata) do
    room_ids = operation["room_ids"]

    with true <- is_list(room_ids) and room_ids != [],
         true <- Enum.all?(room_ids, &present_string?/1),
         true <- Enum.uniq(room_ids) == room_ids do
      requested_ids = MapSet.new(room_ids)

      rooms =
        group.id
        |> active_rooms()
        |> Enum.filter(&MapSet.member?(requested_ids, &1.room_id))

      if length(rooms) == MapSet.size(requested_ids) do
        {:ok, rooms}
      else
        reject(metadata, "invalid_rooms")
      end
    else
      _ -> reject(metadata, "invalid_rooms")
    end
  end

  defp settle_rooms!(_group, [], _metadata, _refund_method), do: {0, 0, 0}

  defp settle_rooms!(group, rooms, metadata, refund_method) do
    room_ids = Enum.map(rooms, & &1.id)

    if refundable_cancellation?(group, metadata.occurred_on) do
      restore_credit_allocations!(room_ids, metadata.occurred_on)
      settle_refundable_room_cash!(group, room_ids, metadata, refund_method)
    else
      consume_credit_allocations!(room_ids)
      retained_cents = reclassify_room_cash!(room_ids, @disp_retained)
      insert_ledger_entry!(group, metadata, @cash_retention, retained_cents)

      {0, retained_cents, 0}
    end
  end

  defp settle_refundable_room_cash!(group, room_ids, metadata, @refund_cash) do
    refunded_cents = reclassify_room_cash!(room_ids, @disp_refunded)
    insert_ledger_entry!(group, metadata, @cash_refund, refunded_cents)

    {refunded_cents, 0, 0}
  end

  defp settle_refundable_room_cash!(group, room_ids, metadata, @refund_hotel_credit) do
    cash_allocations = held_cash_allocations_for_rooms(room_ids)
    cash_cents = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))
    credit_issued_cents = cash_cents + percentage_cents(cash_cents, 10)

    lot = insert_credit_lot!(group.guest_id, metadata, credit_issued_cents)
    insert_credit_entitlements!(lot, cash_allocations)
    reclassify_allocations!(cash_allocations, @disp_converted)
    insert_ledger_entry!(group, metadata, @cash_credit_conversion, cash_cents)

    {0, 0, credit_issued_cents}
  end

  defp restore_credit_allocations!(room_ids, occurred_on) do
    allocations =
      RoomAllocation
      |> where(
        [allocation],
        allocation.room_id in ^room_ids and allocation.allocation_type == @alloc_credit and
          allocation.disposition == @disp_applied
      )
      |> Repo.all()

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {credit_lot_id, allocations} ->
      lot = Repo.get!(CreditLot, credit_lot_id)
      amount_cents = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
      restore_credit_to_lot!(lot, amount_cents, occurred_on)
    end)

    reclassify_allocations!(allocations, @disp_restored)
  end

  defp restore_credit_to_lot!(lot, amount_cents, occurred_on) do
    absorbed_cents = min(lot.unrecovered_clawback_cents || 0, amount_cents)
    restorable_cents = amount_cents - absorbed_cents

    reusable_cents =
      if Date.compare(lot.expires_on, occurred_on) in [:gt, :eq] do
        restorable_cents
      else
        0
      end

    update_credit_lot!(lot, %{
      remaining_cents: lot.remaining_cents + reusable_cents,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed_cents
    })
  end

  defp consume_credit_allocations!(room_ids) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.room_id in ^room_ids and allocation.allocation_type == @alloc_credit and
        allocation.disposition == @disp_applied
    )
    |> Repo.all()
    |> reclassify_allocations!(@disp_consumed)
  end

  defp payment_operation_id(%{operation: operation} = metadata) do
    case operation["payment_operation_id"] do
      payment_operation_id when is_binary(payment_operation_id) and payment_operation_id != "" ->
        {:ok, payment_operation_id}

      _payment_operation_id ->
        reject(metadata, "invalid_operation")
    end
  end

  defp fetch_payment_record(payment_operation_id, non_payment_code, metadata) do
    case fetch_payment_record(payment_operation_id, non_payment_code) do
      {:ok, record, result} -> {:ok, record, result}
      {:error, %{code: code}} -> reject(metadata, code)
    end
  end

  defp fetch_payment_record(payment_operation_id, non_payment_code) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, %{code: "operation_not_found"}}

      %OperationRecord{} = record ->
        result = stored_result!(record)

        if cash_payment_result?(record, result) do
          {:ok, record, result}
        else
          {:error, %{code: non_payment_code}}
        end
    end
  end

  defp cash_payment_result?(%OperationRecord{operation_type: @record_cash_payment}, result) do
    result["status"] == "applied" and is_binary(result["group_id"]) and
      is_integer(result["amount_cents"])
  end

  defp cash_payment_result?(_record, _result), do: false

  defp reducible_held_cash(payment_operation_id, amount_cents, metadata) do
    held_cents = held_cash_for_payment(payment_operation_id)

    cond do
      held_cents == 0 ->
        reject(metadata, "payment_not_reducible")

      amount_cents > held_cents ->
        reject(metadata, "reduction_exceeds_held_cash")

      true ->
        {:ok, held_cents}
    end
  end

  defp chargeable_payment_disposition(payment_operation_id, payment_result, metadata) do
    disposition = payment_disposition(payment_operation_id)
    recorded_cents = payment_result["amount_cents"]
    chargeable_cents = recorded_cents - disposition.reduced_cents

    cond do
      disposition.charged_back_cents > 0 ->
        reject(metadata, "payment_not_chargeable")

      chargeable_cents <= 0 ->
        reject(metadata, "payment_not_chargeable")

      true ->
        {:ok, Map.put(disposition, :chargeable_cents, chargeable_cents)}
    end
  end

  defp payment_reconciliation_data(payment_operation_id, payment_result) do
    disposition = payment_disposition(payment_operation_id)

    data = %{
      payment_operation_id: payment_operation_id,
      original_group_id: payment_result["group_id"],
      recorded_cents: payment_result["amount_cents"],
      held_cents: disposition.held_cents,
      refunded_cents: disposition.refunded_cents,
      retained_cents: disposition.retained_cents,
      converted_to_credit_cents: disposition.converted_cents,
      reduced_cents: disposition.reduced_cents,
      charged_back_cents: disposition.charged_back_cents
    }

    if transferred_cash_payment?(payment_operation_id) do
      Map.put(data, :held_by_group, held_cash_by_group(payment_operation_id))
    else
      data
    end
  end

  defp payment_disposition(payment_operation_id) do
    sums =
      RoomAllocation
      |> where(
        [allocation],
        allocation.allocation_type == @alloc_cash and
          allocation.operation_id == ^payment_operation_id
      )
      |> group_by([allocation], allocation.disposition)
      |> select([allocation], {allocation.disposition, sum(allocation.amount_cents)})
      |> Repo.all()
      |> Map.new(fn {disposition, amount} -> {disposition, amount || 0} end)

    %{
      held_cents: Map.get(sums, @disp_held, 0),
      refunded_cents: Map.get(sums, @disp_refunded, 0),
      retained_cents: Map.get(sums, @disp_retained, 0),
      converted_cents: Map.get(sums, @disp_converted, 0),
      reduced_cents: Map.get(sums, @disp_reduced, 0),
      charged_back_cents: Map.get(sums, @disp_charged_back, 0)
    }
  end

  defp transferred_cash_payment?(payment_operation_id) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.allocation_type == @alloc_cash and
        allocation.operation_id == ^payment_operation_id and
        allocation.transferred == true
    )
    |> Repo.aggregate(:count, :id)
    |> Kernel.>(0)
  end

  defp held_cash_by_group(payment_operation_id) do
    RoomAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where(
      [allocation, room, group],
      allocation.allocation_type == @alloc_cash and
        allocation.operation_id == ^payment_operation_id and
        allocation.disposition == @disp_held and room.status == @active and
        group.status == @active
    )
    |> group_by([_allocation, _room, group], group.group_id)
    |> order_by([_allocation, _room, group], asc: group.group_id)
    |> select([allocation, _room, group], %{
      group_id: group.group_id,
      amount_cents: sum(allocation.amount_cents)
    })
    |> Repo.all()
  end

  defp held_cash_for_payment(payment_operation_id) do
    RoomAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [_allocation, room], group in assoc(room, :group))
    |> where(
      [allocation, room, group],
      allocation.allocation_type == @alloc_cash and
        allocation.operation_id == ^payment_operation_id and
        allocation.disposition == @disp_held and room.status == @active and
        group.status == @active
    )
    |> select([allocation, _room, _group], sum(allocation.amount_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      amount_cents -> amount_cents
    end
  end

  defp reduce_cash_allocations!(payment_operation_id, amount_cents) do
    payment_operation_id
    |> held_cash_allocations_for_payment()
    |> consume_allocation_parts!(amount_cents, @disp_reduced)
  end

  defp held_cash_allocations_for_payment(payment_operation_id) do
    RoomAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [_allocation, room], group in assoc(room, :group))
    |> where(
      [allocation, room, group],
      allocation.allocation_type == @alloc_cash and
        allocation.operation_id == ^payment_operation_id and
        allocation.disposition == @disp_held and room.status == @active and
        group.status == @active
    )
    |> order_by([allocation, _room, _group], desc: allocation.id)
    |> Repo.all()
  end

  defp consume_allocation_parts!(_allocations, 0, _new_disposition), do: []

  defp consume_allocation_parts!([allocation | rest], amount_cents, new_disposition) do
    consumed_cents = min(allocation.amount_cents, amount_cents)
    split_allocation!(allocation, consumed_cents, new_disposition)

    [
      allocation.group_id
      | consume_allocation_parts!(rest, amount_cents - consumed_cents, new_disposition)
    ]
  end

  defp split_allocation!(allocation, amount_cents, new_disposition)
       when amount_cents == allocation.amount_cents do
    update_allocation!(allocation, %{disposition: new_disposition})
  end

  defp split_allocation!(allocation, amount_cents, new_disposition) do
    update_allocation!(allocation, %{amount_cents: allocation.amount_cents - amount_cents})

    insert_room_allocation!(%{
      group_id: allocation.group_id,
      room_id: allocation.room_id,
      credit_lot_id: allocation.credit_lot_id,
      allocation_type: allocation.allocation_type,
      operation_id: allocation.operation_id,
      operation_record_id: allocation.operation_record_id,
      amount_cents: amount_cents,
      disposition: new_disposition,
      transferred: allocation.transferred || false
    })
  end

  defp reclassify_room_cash!(room_ids, new_disposition) do
    allocations = held_cash_allocations_for_rooms(room_ids)
    amount_cents = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
    reclassify_allocations!(allocations, new_disposition)
    amount_cents
  end

  defp held_cash_allocations_for_rooms(room_ids) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.room_id in ^room_ids and allocation.allocation_type == @alloc_cash and
        allocation.disposition == @disp_held
    )
    |> order_by([allocation], asc: allocation.id)
    |> Repo.all()
  end

  defp reclassify_allocation_set!(allocations, new_disposition) do
    amount_cents = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
    reclassify_allocations!(allocations, new_disposition)
    amount_cents
  end

  defp payment_cash_allocations_for_disposition(payment_operation_id, disposition) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.allocation_type == @alloc_cash and
        allocation.operation_id == ^payment_operation_id and
        allocation.disposition == ^disposition
    )
    |> Repo.all()
  end

  defp reclassify_allocations!(allocations, new_disposition) do
    Enum.each(allocations, &update_allocation!(&1, %{disposition: new_disposition}))
  end

  defp insert_credit_entitlements!(nil, _cash_allocations), do: :ok

  defp insert_credit_entitlements!(lot, cash_allocations) do
    cash_allocations
    |> Enum.reduce(0, fn allocation, previous_principal ->
      next_principal = previous_principal + allocation.amount_cents

      entitlement_cents =
        bonus_value_cents(next_principal) - bonus_value_cents(previous_principal)

      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        credit_lot_id: lot.id,
        payment_operation_id: allocation.operation_id,
        principal_cents: allocation.amount_cents,
        entitlement_cents: entitlement_cents
      })
      |> Repo.insert!()

      next_principal
    end)

    :ok
  end

  defp revoke_credit_entitlements!(payment_operation_id) do
    CreditEntitlement
    |> where([entitlement], entitlement.payment_operation_id == ^payment_operation_id)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removable_cents = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered_cents = entitlement.entitlement_cents - removable_cents

      update_credit_lot!(lot, %{
        remaining_cents: lot.remaining_cents - removable_cents,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered_cents
      })
    end)
  end

  defp bonus_value_cents(principal_cents),
    do: principal_cents + percentage_cents(principal_cents, 10)

  defp allocate_cash_to_rooms!(group, metadata, amount_cents) do
    allocate_to_active_rooms!(group, amount_cents, %{
      allocation_type: @alloc_cash,
      operation_id: metadata.operation_id,
      operation_record_id: metadata.operation_record_id,
      disposition: @disp_held
    })
  end

  defp allocate_credit_to_rooms!(group, lot, metadata, amount_cents) do
    allocate_to_active_rooms!(group, amount_cents, %{
      allocation_type: @alloc_credit,
      operation_id: metadata.operation_id,
      operation_record_id: metadata.operation_record_id,
      credit_lot_id: lot.id,
      disposition: @disp_applied
    })
  end

  defp allocate_to_active_rooms!(group, amount_cents, attrs) do
    rooms = active_rooms(group.id)

    remaining_cents =
      Enum.reduce(rooms, amount_cents, fn room, remaining_cents ->
        if remaining_cents == 0 do
          0
        else
          open_cents = room.deposit_due_cents - active_room_funding_cents(room.id)
          allocation_cents = min(max(open_cents, 0), remaining_cents)

          if allocation_cents > 0 do
            insert_room_allocation!(
              attrs
              |> Map.merge(%{
                group_id: group.id,
                room_id: room.id,
                amount_cents: allocation_cents
              })
            )
          end

          remaining_cents - allocation_cents
        end
      end)

    if remaining_cents != 0 do
      raise "failed to allocate #{remaining_cents} cents for group #{group.group_id}"
    end
  end

  defp draw_transfer_units!(amount_cents, allocations) do
    allocations
    |> Enum.reduce_while({amount_cents, []}, fn allocation, {remaining_cents, units} ->
      if remaining_cents == 0 do
        {:halt, {0, units}}
      else
        moved_cents = min(allocation.amount_cents, remaining_cents)

        if moved_cents == allocation.amount_cents do
          update_allocation!(allocation, %{disposition: @disp_transferred, transferred: true})
        else
          update_allocation!(allocation, %{amount_cents: allocation.amount_cents - moved_cents})
        end

        unit = %{
          credit_lot_id: allocation.credit_lot_id,
          allocation_type: allocation.allocation_type,
          operation_id: allocation.operation_id,
          operation_record_id: allocation.operation_record_id,
          amount_cents: moved_cents,
          disposition: allocation.disposition,
          transferred: true
        }

        {:cont, {remaining_cents - moved_cents, [unit | units]}}
      end
    end)
    |> case do
      {0, units} -> Enum.reverse(units)
      {remaining_cents, _units} -> raise "failed to draw #{remaining_cents} transfer cents"
    end
  end

  defp allocate_transfer_units_to_destination!(units, group) do
    remaining_units =
      Enum.reduce(active_rooms(group.id), units, fn room, remaining_units ->
        open_cents = max(room.deposit_due_cents - active_room_funding_cents(room.id), 0)
        allocate_transfer_units_to_room!(group, room, remaining_units, open_cents)
      end)

    remaining_cents = Enum.reduce(remaining_units, 0, &(&1.amount_cents + &2))

    if remaining_cents != 0 do
      raise "failed to allocate #{remaining_cents} transferred cents for group #{group.group_id}"
    end
  end

  defp allocate_transfer_units_to_room!(_group, _room, units, 0), do: units
  defp allocate_transfer_units_to_room!(_group, _room, [], _open_cents), do: []

  defp allocate_transfer_units_to_room!(group, room, [unit | rest], open_cents) do
    allocation_cents = min(unit.amount_cents, open_cents)

    insert_room_allocation!(
      unit
      |> Map.merge(%{
        group_id: group.id,
        room_id: room.id,
        amount_cents: allocation_cents
      })
    )

    cond do
      allocation_cents == unit.amount_cents ->
        allocate_transfer_units_to_room!(group, room, rest, open_cents - allocation_cents)

      true ->
        [Map.put(unit, :amount_cents, unit.amount_cents - allocation_cents) | rest]
    end
  end

  defp active_room_funding_cents(room_id) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.room_id == ^room_id and
        ((allocation.allocation_type == @alloc_cash and allocation.disposition == @disp_held) or
           (allocation.allocation_type == @alloc_credit and
              allocation.disposition == @disp_applied))
    )
    |> select([allocation], sum(allocation.amount_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      amount_cents -> amount_cents
    end
  end

  defp insert_room_allocation!(attrs) do
    %RoomAllocation{}
    |> RoomAllocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp update_allocation!(allocation, attrs) do
    allocation
    |> RoomAllocation.changeset(attrs)
    |> Repo.update!()
  end

  defp cancel_rooms!(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Room.changeset(%{status: @cancelled})
      |> Repo.update!()
    end)
  end

  defp active_rooms(group_id) do
    Room
    |> where([room], room.group_id == ^group_id and room.status == @active)
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp active_room_count(group_id) do
    Room
    |> where([room], room.group_id == ^group_id and room.status == @active)
    |> select([room], count(room.id))
    |> Repo.one()
  end

  defp refundable_cancellation?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version) and policy_version != "" do
    policy_version
  end

  defp policy_version(%Group{} = group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp refundable_until(%Group{} = group) do
    case policy_version(group) do
      @flex_14 -> Date.add(group.arrival_on, -14)
      @flex_30 -> Date.add(group.arrival_on, -30)
      @advance_nonrefundable -> nil
    end
  end

  defp refundable_until_data(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp percentage_cents(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    max(group.deposit_due_cents - deposit_paid_cents(group), 0)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp deposit_paid_cents(%Group{deposit_paid_cents: deposit_paid_cents})
       when is_integer(deposit_paid_cents) do
    deposit_paid_cents
  end

  defp deposit_paid_cents(%Group{} = group), do: cash_paid_cents(group) + credit_paid_cents(group)

  defp cash_paid_cents(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  defp cash_paid_cents(%Group{deposit_paid_cents: deposit_paid_cents})
       when is_integer(deposit_paid_cents),
       do: deposit_paid_cents

  defp cash_paid_cents(%Group{}), do: 0

  defp credit_paid_cents(%Group{credit_paid_cents: credit_paid_cents})
       when is_integer(credit_paid_cents),
       do: credit_paid_cents

  defp credit_paid_cents(%Group{}), do: 0

  defp credit_liability_cents(as_of) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on >= ^as_of)
      |> select([lot], sum(lot.remaining_cents))
      |> Repo.one()
      |> case do
        nil -> 0
        amount_cents -> amount_cents
      end

    applied_cents =
      RoomAllocation
      |> join(:inner, [allocation], room in assoc(allocation, :room))
      |> join(:inner, [_allocation, room], group in assoc(room, :group))
      |> where(
        [allocation, room, group],
        allocation.allocation_type == @alloc_credit and allocation.disposition == @disp_applied and
          room.status == @active and group.status == @active
      )
      |> select([allocation, _room, _group], sum(allocation.amount_cents))
      |> Repo.one()
      |> case do
        nil -> 0
        amount_cents -> amount_cents
      end

    available_cents + applied_cents
  end

  defp credit_shortfall_cents do
    applied_by_lot =
      RoomAllocation
      |> join(:inner, [allocation], room in assoc(allocation, :room))
      |> join(:inner, [_allocation, room], group in assoc(room, :group))
      |> where(
        [allocation, room, group],
        allocation.allocation_type == @alloc_credit and allocation.disposition == @disp_applied and
          room.status == @active and group.status == @active
      )
      |> group_by([allocation, _room, _group], allocation.credit_lot_id)
      |> select(
        [allocation, _room, _group],
        {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Repo.all()
      |> Map.new(fn {credit_lot_id, amount_cents} -> {credit_lot_id, amount_cents || 0} end)

    CreditLot
    |> where([lot], lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end

  defp available_credit_lots(guest_id, as_of) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp ensure_all_active_group_accounting! do
    Group
    |> where([group], group.status == @active)
    |> Repo.all()
    |> Enum.each(fn group ->
      group
      |> ensure_group_accounting!()
      |> sync_group_totals!()
    end)
  end

  defp ensure_group_accounting!(%Group{} = group) do
    if room_allocation_count(group.id) == 0 do
      backfill_active_group_accounting!(group)
    end

    fetch_group(group.group_id)
  end

  defp room_allocation_count(group_id) do
    RoomAllocation
    |> where([allocation], allocation.group_id == ^group_id)
    |> select([allocation], count(allocation.id))
    |> Repo.one()
  end

  defp backfill_active_group_accounting!(%Group{status: @active} = group) do
    group
    |> backfill_funding_events()
    |> Enum.reject(&(&1.amount_cents <= 0))
    |> Enum.each(fn
      %{kind: :cash} = event ->
        allocate_to_active_rooms!(group, event.amount_cents, %{
          allocation_type: @alloc_cash,
          operation_id: event.operation_id,
          operation_record_id: event.operation_record_id,
          disposition: @disp_held
        })

      %{kind: :credit} = event ->
        allocate_to_active_rooms!(group, event.amount_cents, %{
          allocation_type: @alloc_credit,
          operation_id: event.operation_id,
          operation_record_id: event.operation_record_id,
          credit_lot_id: event.credit_lot_id,
          disposition: @disp_applied
        })
    end)
  end

  defp backfill_active_group_accounting!(%Group{}), do: :ok

  defp backfill_funding_events(group) do
    cash_entries =
      LedgerEntry
      |> where([entry], entry.group_id == ^group.id and entry.entry_type == @cash_payment)
      |> order_by([entry], asc: entry.inserted_at, asc: entry.id)
      |> Repo.all()

    credit_applications =
      CreditApplication
      |> where([application], application.group_id == ^group.id)
      |> order_by([application], asc: application.inserted_at, asc: application.id)
      |> Repo.all()

    operation_ids =
      (Enum.map(cash_entries, & &1.operation_id) ++
         Enum.map(credit_applications, & &1.operation_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    operation_records =
      OperationRecord
      |> where([record], record.operation_id in ^operation_ids)
      |> Repo.all()
      |> Map.new(&{&1.operation_id, &1})

    {legacy_cash_cents, durable_cash_events} =
      cash_entries
      |> Enum.with_index()
      |> Enum.reduce({0, []}, fn {entry, source_index}, {legacy_cents, durable_events} ->
        case Map.get(operation_records, entry.operation_id) do
          %OperationRecord{operation_type: @record_cash_payment} = record ->
            event = %{
              kind: :cash,
              operation_id: entry.operation_id,
              operation_record_id: record.id,
              source_index: source_index,
              amount_cents: entry.amount_cents
            }

            {legacy_cents, [event | durable_events]}

          _record ->
            {legacy_cents + entry.amount_cents, durable_events}
        end
      end)

    ledger_cash_cents = Enum.reduce(cash_entries, 0, &(&1.amount_cents + &2))
    legacy_cash_cents = max(legacy_cash_cents + cash_paid_cents(group) - ledger_cash_cents, 0)

    {legacy_credit_events, durable_credit_events} =
      credit_applications
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {application, source_index}, {legacy_events, durable_events} ->
        case Map.get(operation_records, application.operation_id) do
          %OperationRecord{operation_type: @apply_hotel_credit} = record ->
            event = %{
              kind: :credit,
              operation_id: application.operation_id,
              operation_record_id: record.id,
              source_index: source_index,
              credit_lot_id: application.credit_lot_id,
              amount_cents: application.amount_cents
            }

            {legacy_events, [event | durable_events]}

          _record ->
            event = %{
              kind: :credit,
              operation_id: nil,
              operation_record_id: nil,
              source_index: source_index,
              credit_lot_id: application.credit_lot_id,
              amount_cents: application.amount_cents
            }

            {[event | legacy_events], durable_events}
        end
      end)

    legacy_cash_events =
      if legacy_cash_cents > 0 do
        [
          %{
            kind: :cash,
            operation_id: nil,
            operation_record_id: nil,
            amount_cents: legacy_cash_cents
          }
        ]
      else
        []
      end

    durable_events =
      (durable_cash_events ++ durable_credit_events)
      |> Enum.sort_by(&{&1.operation_record_id, event_kind_order(&1.kind), &1.source_index})

    legacy_cash_events ++ Enum.reverse(legacy_credit_events) ++ durable_events
  end

  defp event_kind_order(:cash), do: 0
  defp event_kind_order(:credit), do: 1

  defp sync_groups_after_funding_change!(addressed_group, changed_group_ids) do
    changed_group_ids
    |> MapSet.new()
    |> MapSet.put(addressed_group.id)
    |> Enum.map(fn group_id ->
      group =
        if group_id == addressed_group.id do
          addressed_group
        else
          Repo.get!(Group, group_id)
        end

      group = sync_group_totals!(group, %{revision: group.revision + 1})

      {group.id, group}
    end)
    |> Map.new()
  end

  defp sync_group_totals!(group, attrs \\ %{}) do
    {lodging_total_cents, deposit_due_cents} = active_room_totals(group.id)
    {cash_paid_cents, credit_paid_cents} = active_funding_totals(group.id)
    deposit_paid_cents = cash_paid_cents + credit_paid_cents

    update_group!(
      group,
      Map.merge(
        %{
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          cash_paid_cents: cash_paid_cents,
          credit_paid_cents: credit_paid_cents,
          deposit_paid_cents: deposit_paid_cents
        },
        attrs
      )
    )
  end

  defp active_room_totals(group_id) do
    Room
    |> where([room], room.group_id == ^group_id and room.status == @active)
    |> select([room], {sum(room.lodging_total_cents), sum(room.deposit_due_cents)})
    |> Repo.one()
    |> case do
      {nil, nil} ->
        {0, 0}

      {lodging_total_cents, deposit_due_cents} ->
        {lodging_total_cents || 0, deposit_due_cents || 0}
    end
  end

  defp active_funding_totals(group_id) do
    RoomAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> where(
      [allocation, room],
      allocation.group_id == ^group_id and room.status == @active and
        ((allocation.allocation_type == @alloc_cash and allocation.disposition == @disp_held) or
           (allocation.allocation_type == @alloc_credit and
              allocation.disposition == @disp_applied))
    )
    |> group_by([allocation, _room], allocation.allocation_type)
    |> select([allocation, _room], {allocation.allocation_type, sum(allocation.amount_cents)})
    |> Repo.all()
    |> Map.new(fn {allocation_type, amount} -> {allocation_type, amount || 0} end)
    |> then(fn totals -> {Map.get(totals, @alloc_cash, 0), Map.get(totals, @alloc_credit, 0)} end)
  end

  defp room_allocation_sums([]), do: %{}

  defp room_allocation_sums(room_ids) do
    RoomAllocation
    |> where(
      [allocation],
      allocation.room_id in ^room_ids and
        ((allocation.allocation_type == @alloc_cash and allocation.disposition == @disp_held) or
           (allocation.allocation_type == @alloc_credit and
              allocation.disposition == @disp_applied))
    )
    |> group_by([allocation], [allocation.room_id, allocation.allocation_type])
    |> select([allocation], {
      allocation.room_id,
      allocation.allocation_type,
      sum(allocation.amount_cents)
    })
    |> Repo.all()
    |> Map.new(fn {room_id, allocation_type, amount} ->
      {{room_id, allocation_type}, amount || 0}
    end)
  end

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update!()
  end

  defp update_credit_lot!(lot, attrs) do
    lot
    |> CreditLot.changeset(attrs)
    |> Repo.update!()
  end

  defp insert_ledger_entry!(_group, _metadata, _entry_type, 0), do: :ok

  defp insert_ledger_entry!(group, metadata, entry_type, amount_cents) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{
      group_id: group.id,
      operation_id: metadata.operation_id,
      entry_type: entry_type,
      amount_cents: amount_cents,
      occurred_on: metadata.occurred_on
    })
    |> Repo.insert!()
  end

  defp insert_credit_lot!(_guest_id, _metadata, 0), do: nil

  defp insert_credit_lot!(guest_id, metadata, amount_cents) do
    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: metadata.operation_id,
      remaining_cents: amount_cents,
      expires_on: Date.add(metadata.occurred_on, 365),
      unrecovered_clawback_cents: 0
    })
    |> Repo.insert!()
  end

  defp insert_credit_application!(group, lot, metadata, amount_cents) do
    %CreditApplication{}
    |> CreditApplication.changeset(%{
      group_id: group.id,
      credit_lot_id: lot.id,
      operation_id: metadata.operation_id,
      amount_cents: amount_cents
    })
    |> Repo.insert!()
  end

  defp apply_result(metadata, fields) do
    {:ok,
     metadata
     |> base_result("applied")
     |> Map.merge(fields)}
  end

  defp reject(metadata_or_operation, code) do
    {:error,
     metadata_or_operation
     |> base_result("rejected")
     |> Map.put(:code, code)}
  end

  defp reject(metadata_or_operation, code, fields) do
    {:error,
     metadata_or_operation
     |> base_result("rejected")
     |> Map.put(:code, code)
     |> Map.merge(fields)}
  end

  defp base_result(%{operation_id: operation_id}, status) when is_binary(operation_id) do
    %{operation_id: operation_id, status: status}
  end

  defp base_result(operation, status) when is_map(operation) do
    operation_id =
      case operation["operation_id"] do
        operation_id when is_binary(operation_id) -> operation_id
        _other -> nil
      end

    %{operation_id: operation_id, status: status}
  end

  defp base_result(_operation, status), do: %{operation_id: nil, status: status}

  defp room_data(room, room_sums) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_total_cents: room.lodging_total_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: Map.get(room_sums, {room.id, @alloc_cash}, 0),
      credit_paid_cents: Map.get(room_sums, {room.id, @alloc_credit}, 0)
    }
  end

  defp credit_lot_data(%CreditLot{} = lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp fetch_group(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{} = group) do
    rooms_query = from room in Room, order_by: [asc: room.position]
    Repo.preload(group, rooms: rooms_query)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp as_of_date(%Date{} = date), do: date

  defp as_of_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> Date.utc_today()
    end
  end

  defp as_of_date(_value), do: Date.utc_today()

  defp present_string?(value), do: is_binary(value) and value != ""
end
