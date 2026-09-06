defmodule GroupStay.Operations do
  import Ecto.Query
  import Ecto.Changeset

  alias GroupStay.{
    CancellationPolicy,
    CashAllocation,
    CreditLot,
    CreditLotEntitlement,
    Group,
    GroupCreditAllocation,
    GroupRoom,
    OperationRecord,
    Repo
  }

  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"
  @cash_visible_dispositions ["held", "refunded", "retained", "converted"]
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &apply/1)

  def get(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, Jason.decode!(record.result_json)}
    end
  end

  def get(_operation_id), do: {:error, :operation_not_found}

  def payment_reconciliation(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> {:error, :operation_not_found}
      record -> reconcile_payment(record, payment_operation_id)
    end
  end

  def payment_reconciliation(_payment_operation_id), do: {:error, :operation_not_found}

  def apply(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      apply_known_operation(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  def apply(_operation), do: rejected(nil, "invalid_operation")

  defp apply_known_operation(%{"type" => "open_group"} = operation, operation_id) do
    in_transaction(operation, operation_id, &open_group(&1, &2))
  end

  defp apply_known_operation(%{"type" => type} = operation, operation_id)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms"
            ] do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, group} <- find_group(current_operation, current_id),
           :ok <- check_revision(current_operation, current_id, group),
           :ok <- active_group(current_id, group) do
        case type do
          "record_cash_payment" -> record_cash_payment(current_operation, current_id, group)
          "apply_hotel_credit" -> apply_hotel_credit(current_operation, current_id, group)
          "reschedule_group" -> reschedule_group(current_operation, current_id, group)
          "cancel_group" -> cancel_group(current_operation, current_id, group)
          "cancel_rooms" -> cancel_rooms(current_operation, current_id, group)
        end
      end
    end)
  end

  defp apply_known_operation(%{"type" => "transfer_deposit"} = operation, operation_id) do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, source} <- find_transfer_group(current_operation, current_id, "source_group_id"),
           {:ok, destination} <-
             find_transfer_group(current_operation, current_id, "destination_group_id"),
           :ok <- check_revision(current_operation, current_id, source),
           :ok <-
             check_revision_for(
               current_operation,
               current_id,
               destination,
               "destination_expected_revision"
             ) do
        transfer_deposit(current_operation, current_id, source, destination)
      end
    end)
  end

  defp apply_known_operation(%{"type" => "reduce_cash_payment"} = operation, operation_id) do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, _record, _result, group} <-
             payment_target(current_operation, current_id, "payment_not_reducible"),
           :ok <- check_revision(current_operation, current_id, group) do
        reduce_cash_payment(current_operation, current_id, group)
      end
    end)
  end

  defp apply_known_operation(%{"type" => "charge_back_payment"} = operation, operation_id) do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, _record, _result, group} <-
             payment_target(current_operation, current_id, "payment_not_chargeable"),
           :ok <- check_revision(current_operation, current_id, group) do
        charge_back_payment(current_operation, current_id, group)
      end
    end)
  end

  defp apply_known_operation(operation, operation_id) do
    in_transaction(operation, operation_id, fn _operation, current_id ->
      reject(current_id, "invalid_operation")
    end)
  end

  defp in_transaction(operation, operation_id, function) do
    payload_json = encode_payload(operation)

    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get_by(OperationRecord, operation_id: operation_id) do
            nil ->
              result = execute_operation(function, operation, operation_id)
              persist_operation!(operation, operation_id, payload_json, result)
              Jason.decode!(encode_result(result))

            record ->
              if record.payload_json == payload_json do
                Jason.decode!(record.result_json)
              else
                rejected(operation_id, "operation_id_conflict")
              end
          end
        end,
        mode: :immediate
      )

    result
  end

  defp execute_operation(function, operation, operation_id) do
    Repo.query!("SAVEPOINT group_stay_operation")

    try do
      result = function.(operation, operation_id)
      Repo.query!("RELEASE SAVEPOINT group_stay_operation")
      result
    catch
      :throw, {:group_stay_rejected, result} ->
        Repo.query!("ROLLBACK TO SAVEPOINT group_stay_operation")
        Repo.query!("RELEASE SAVEPOINT group_stay_operation")
        result
    end
  end

  defp persist_operation!(operation, operation_id, payload_json, result) do
    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json,
      result_json: encode_result(result)
    })
    |> Repo.insert!()
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp encode_payload(operation), do: operation |> canonicalize() |> Jason.encode!()
  defp encode_result(result), do: Jason.encode!(result)

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested_value} -> {key, canonicalize(nested_value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp open_group(operation, operation_id) do
    with {:ok, attrs} <- validate_open(operation),
         nil <- Repo.get_by(Group, group_id: attrs.group_id) do
      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          case insert_rooms(group, attrs.rooms) do
            :ok ->
              %{
                operation_id: operation_id,
                status: "applied",
                group_id: group.group_id,
                deposit_due_cents: group.deposit_due_cents,
                revision: group.revision
              }

            {:error, :invalid_rooms} ->
              reject(operation_id, "invalid_rooms")
          end

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            reject(operation_id, "group_already_exists")
          else
            reject(operation_id, "invalid_operation")
          end
      end
    else
      {:error, code} -> reject(operation_id, code)
      %Group{} -> reject(operation_id, "group_already_exists")
    end
  end

  defp find_group(operation, operation_id) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> reject_and_rollback({"group_not_found", %{}, operation_id})
          group -> {:ok, group}
        end

      _ ->
        reject_and_rollback({"invalid_operation", %{}, operation_id})
    end
  end

  defp find_transfer_group(operation, operation_id, key) do
    case Map.get(operation, key) do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> reject_and_rollback({"group_not_found", %{group_id: group_id}, operation_id})
          group -> {:ok, group}
        end

      _ ->
        reject_and_rollback({"invalid_operation", %{}, operation_id})
    end
  end

  defp check_revision(operation, operation_id, %Group{} = group) do
    check_revision_for(operation, operation_id, group, "expected_revision")
  end

  defp check_revision_for(operation, operation_id, %Group{} = group, key) do
    if Map.has_key?(operation, key) and Map.get(operation, key) !== group.revision do
      reject_and_rollback({
        "stale_revision",
        %{
          group_id: group.group_id,
          expected_revision: Map.get(operation, key),
          actual_revision: group.revision
        },
        operation_id
      })
    else
      :ok
    end
  end

  defp active_group(_operation_id, %Group{status: "active"}), do: :ok

  defp active_group(operation_id, %Group{}),
    do: reject_and_rollback({"group_not_active", %{}, operation_id})

  defp transfer_deposit(operation, operation_id, source, destination) do
    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        reject_and_rollback({"invalid_transfer", %{}, operation_id})

      source.status != "active" ->
        reject_and_rollback({"group_not_active", %{group_id: source.group_id}, operation_id})

      destination.status != "active" ->
        reject_and_rollback({"group_not_active", %{group_id: destination.group_id}, operation_id})

      true ->
        case usable_amount(Map.get(operation, "amount_cents")) do
          {:error, code} ->
            reject_and_rollback({code, %{}, operation_id})

          {:ok, amount_cents} ->
            held = held_funding(source.id)
            outstanding = outstanding_deposit(destination)

            cond do
              amount_cents > held ->
                reject_and_rollback({"transfer_exceeds_held_funding", %{}, operation_id})

              amount_cents > outstanding ->
                reject_and_rollback({"transfer_exceeds_outstanding", %{}, operation_id})

              true ->
                move_deposit_allocations(source.id, destination.id, amount_cents)

                source = sync_group!(source)
                destination = sync_group!(destination)

                %{
                  operation_id: operation_id,
                  status: "applied",
                  source_group_id: source.group_id,
                  destination_group_id: destination.group_id,
                  amount_cents: amount_cents,
                  source_outstanding_deposit_cents: outstanding_deposit(source),
                  destination_outstanding_deposit_cents: outstanding_deposit(destination),
                  source_revision: source.revision,
                  destination_revision: destination.revision
                }
            end
        end
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(Map.get(operation, "amount_cents")),
         outstanding when amount_cents <= outstanding <- outstanding_deposit(group) do
      allocate_cash(group, operation_id, amount_cents)
      group = sync_group!(group)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: group.revision
      }
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
      _ -> reject_and_rollback({"payment_exceeds_outstanding", %{}, operation_id})
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(Map.get(operation, "amount_cents")),
         outstanding when amount_cents <= outstanding <- outstanding_deposit(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         :ok <- enough_credit(lots, amount_cents) do
      allocate_credit(group, operation_id, lots, amount_cents)
      group = sync_group!(group)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: group.revision
      }
    else
      {:error, "insufficient_credit"} ->
        reject_and_rollback({"insufficient_credit", %{}, operation_id})

      {:error, code} ->
        reject_and_rollback({code, %{}, operation_id})

      _ ->
        reject_and_rollback({"payment_exceeds_outstanding", %{}, operation_id})
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(Map.get(operation, "occurred_on")),
         {:ok, new_arrival_on} <- parse_date(Map.get(operation, "new_arrival_on")),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      arrival_shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, arrival_shift)
      group = update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        policy_version: group.policy_version,
        refundable_until:
          CancellationPolicy.refundable_until(group.policy_version, new_arrival_on)
          |> format_date(),
        revision: group.revision
      }
    else
      _ -> reject_and_rollback({"invalid_stay", %{}, operation_id})
    end
  end

  defp cancel_group(operation, operation_id, group) do
    room_ids =
      group.id
      |> rooms_with_balances()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(& &1.room_id)

    cancel_selected_rooms(operation, operation_id, group, room_ids, false)
  end

  defp cancel_rooms(operation, operation_id, group) do
    with {:ok, room_ids} <- requested_room_ids(Map.get(operation, "room_ids")),
         {:ok, rooms} <- active_requested_rooms(group.id, room_ids) do
      selected_ids = Enum.map(rooms, & &1.room_id)
      cancel_selected_rooms(operation, operation_id, group, selected_ids, true)
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
    end
  end

  defp cancel_selected_rooms(operation, operation_id, group, room_ids, partial?) do
    with {:ok, occurred_on} <- parse_date(Map.get(operation, "occurred_on")),
         {:ok, refund_method} <- refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- available_refund_method(refund_method, refundable) do
      balances = rooms_with_balances(group.id)
      selected_rooms = Enum.filter(balances, &(&1.room_id in room_ids))
      selected_room_record_ids = Enum.map(selected_rooms, & &1.id)

      cash_allocations = held_cash_allocations(selected_room_record_ids)

      {refunded_cents, retained_cents, credit_issued_cents, converted_cents} =
        settle_cash_allocations(
          cash_allocations,
          group,
          occurred_on,
          refund_method,
          refundable,
          operation_id
        )

      settle_credit_allocations(selected_room_record_ids, occurred_on, refundable)
      mark_rooms_cancelled(selected_room_record_ids)

      new_status =
        if Enum.any?(balances, &(&1.status == "active" and &1.room_id not in room_ids)),
          do: "active",
          else: "cancelled"

      group =
        sync_group!(group, %{
          status: new_status,
          refunded_cents: group.refunded_cents + refunded_cents,
          retained_cents: group.retained_cents + retained_cents,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents
        })

      result = %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      }

      if partial? do
        Map.put(result, :cancelled_room_ids, room_ids)
      else
        result
      end
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
    end
  end

  defp settle_cash_allocations(
         [],
         _group,
         _occurred_on,
         _refund_method,
         _refundable,
         _operation_id
       ),
       do: {0, 0, 0, 0}

  defp settle_cash_allocations(
         allocations,
         group,
         occurred_on,
         "hotel_credit",
         true,
         operation_id
       ) do
    cash_cents = Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
    credit_issued_cents = credit_value(cash_cents)

    lot =
      if credit_issued_cents > 0 do
        %CreditLot{}
        |> CreditLot.changeset(%{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 366),
          unrecovered_clawback_cents: 0
        })
        |> Repo.insert!()
      end

    create_credit_entitlements(lot, allocations)

    Enum.each(allocations, fn allocation ->
      allocation
      |> change(disposition: "converted", credit_lot_id: lot && lot.id)
      |> Repo.update!()
    end)

    {0, 0, credit_issued_cents, cash_cents}
  end

  defp settle_cash_allocations(allocations, _group, _occurred_on, "cash", true, _operation_id) do
    Enum.each(allocations, fn allocation ->
      allocation |> change(disposition: "refunded", credit_lot_id: nil) |> Repo.update!()
    end)

    {Enum.reduce(allocations, 0, &(&1.amount_cents + &2)), 0, 0, 0}
  end

  defp settle_cash_allocations(allocations, _group, _occurred_on, "cash", false, _operation_id) do
    Enum.each(allocations, fn allocation ->
      allocation |> change(disposition: "retained", credit_lot_id: nil) |> Repo.update!()
    end)

    {0, Enum.reduce(allocations, 0, &(&1.amount_cents + &2)), 0, 0}
  end

  defp create_credit_entitlements(nil, _allocations), do: :ok

  defp create_credit_entitlements(lot, allocations) do
    allocations
    |> sort_cash_allocations_by_funding_order()
    |> Enum.reduce({0, nil, 0}, fn allocation, {running, source, source_amount} ->
      allocation_source = allocation.payment_operation_id

      if allocation_source == source do
        {running + allocation.amount_cents, source, source_amount + allocation.amount_cents}
      else
        insert_entitlement(lot, source, running, source_amount)
        {running + allocation.amount_cents, allocation_source, allocation.amount_cents}
      end
    end)
    |> then(fn {running, source, source_amount} ->
      insert_entitlement(lot, source, running, source_amount)
    end)
  end

  defp insert_entitlement(_lot, nil, _running, _source_amount), do: :ok
  defp insert_entitlement(_lot, _source, _running, 0), do: :ok

  defp insert_entitlement(lot, source, running, source_amount) do
    previous = running - source_amount
    amount = credit_value(running) - credit_value(previous)

    if amount > 0 do
      %CreditLotEntitlement{}
      |> CreditLotEntitlement.changeset(%{
        credit_lot_id: lot.id,
        payment_operation_id: source,
        amount_cents: amount,
        revoked_cents: 0
      })
      |> Repo.insert!()
    end
  end

  defp settle_credit_allocations(room_ids, occurred_on, refundable) do
    Repo.all(
      from allocation in GroupCreditAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.status == "held",
        order_by: [asc: allocation.allocation_order, asc: allocation.id]
    )
    |> Enum.each(fn allocation ->
      if refundable do
        restore_credit_allocation(allocation, occurred_on)
      else
        allocation |> change(status: "consumed") |> Repo.update!()
      end
    end)
  end

  defp restore_credit_allocation(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
    available_amount = allocation.amount_cents - absorbed

    remaining =
      if available_amount > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
        lot.remaining_cents + available_amount
      else
        lot.remaining_cents
      end

    lot
    |> change(
      remaining_cents: remaining,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    )
    |> Repo.update!()

    allocation |> change(status: "restored") |> Repo.update!()
  end

  defp mark_rooms_cancelled(room_ids) do
    Enum.each(room_ids, fn room_id ->
      Repo.get!(GroupRoom, room_id)
      |> change(status: "cancelled")
      |> Repo.update!()
    end)
  end

  defp reduce_cash_payment(operation, operation_id, group) do
    with {:ok, amount_cents} <- usable_amount(Map.get(operation, "amount_cents")) do
      allocations = cash_allocations_for_payment(Map.get(operation, "payment_operation_id"))
      held_cents = sum_disposition(allocations, "held")

      cond do
        held_cents == 0 ->
          reject_and_rollback({"payment_not_reducible", %{}, operation_id})

        amount_cents > held_cents ->
          reject_and_rollback({"reduction_exceeds_held_cash", %{}, operation_id})

        true ->
          affected_amounts = reduce_cash_allocations(allocations, amount_cents)
          group = sync_groups_after_reduction(group, affected_amounts)

          %{
            operation_id: operation_id,
            status: "applied",
            payment_operation_id: operation["payment_operation_id"],
            group_id: group.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding_deposit(group),
            revision: group.revision
          }
      end
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
    end
  end

  defp reduce_cash_allocations(allocations, amount_cents) do
    allocations
    |> Enum.filter(&(&1.disposition == "held"))
    |> Enum.sort_by(&{&1.allocation_order, &1.id}, :desc)
    |> Enum.reduce_while({amount_cents, %{}}, fn allocation, {remaining, affected} ->
      reduced = min(allocation.amount_cents, remaining)

      if reduced == allocation.amount_cents do
        allocation |> change(disposition: "reduced") |> Repo.update!()
      else
        allocation |> change(amount_cents: allocation.amount_cents - reduced) |> Repo.update!()

        %CashAllocation{}
        |> CashAllocation.changeset(%{
          group_record_id: allocation.group_record_id,
          group_room_id: allocation.group_room_id,
          payment_operation_id: allocation.payment_operation_id,
          amount_cents: reduced,
          disposition: "reduced",
          allocation_order: next_allocation_order(),
          transferred: allocation.transferred
        })
        |> Repo.insert!()
      end

      remaining = remaining - reduced
      affected = Map.update(affected, allocation.group_record_id, reduced, &(&1 + reduced))
      if remaining == 0, do: {:halt, {0, affected}}, else: {:cont, {remaining, affected}}
    end)
    |> elem(1)
  end

  defp sync_groups_after_reduction(group, affected_amounts) do
    sync_groups_after_cash_change(group, affected_amounts, 0, fn current, amount ->
      %{cash_reduced_cents: current.cash_reduced_cents + amount}
    end)
  end

  defp charge_back_payment(operation, operation_id, group) do
    payment_operation_id = Map.get(operation, "payment_operation_id")
    allocations = cash_allocations_for_payment(payment_operation_id)
    reduced_cents = sum_disposition(allocations, "reduced")
    charged_back_cents = sum_disposition(allocations, "charged_back")
    recorded_cents = payment_recorded_cents(payment_operation_id)

    cond do
      charged_back_cents > 0 or reduced_cents >= recorded_cents ->
        reject_and_rollback({"payment_not_chargeable", %{}, operation_id})

      allocations == [] ->
        reject_and_rollback({"payment_not_chargeable", %{}, operation_id})

      true ->
        reclassifiable =
          Enum.filter(allocations, fn allocation ->
            allocation.disposition in ["held", "refunded", "retained", "converted"]
          end)

        if reclassifiable == [] do
          reject_and_rollback({"payment_not_chargeable", %{}, operation_id})
        end

        Enum.each(reclassifiable, fn allocation ->
          allocation |> change(disposition: "charged_back") |> Repo.update!()
        end)

        revoke_credit_entitlements(payment_operation_id)

        total = Enum.reduce(reclassifiable, 0, &(&1.amount_cents + &2))

        group_changes =
          Enum.reduce(reclassifiable, %{}, fn allocation, changes ->
            attrs = Map.get(changes, allocation.group_record_id, %{})

            attrs =
              attrs
              |> Map.update(
                :cash_charged_back_cents,
                allocation.amount_cents,
                &(&1 + allocation.amount_cents)
              )
              |> add_cash_disposition_change(allocation.disposition, allocation.amount_cents)

            Map.put(changes, allocation.group_record_id, attrs)
          end)

        group =
          sync_groups_after_cash_change(group, group_changes, %{}, fn current, attrs ->
            Map.merge(attrs, %{
              refunded_cents: current.refunded_cents + Map.get(attrs, :refunded_delta, 0),
              retained_cents: current.retained_cents + Map.get(attrs, :retained_delta, 0),
              cash_converted_to_credit_cents:
                current.cash_converted_to_credit_cents + Map.get(attrs, :converted_delta, 0)
            })
            |> Map.drop([:refunded_delta, :retained_delta, :converted_delta])
          end)

        %{
          operation_id: operation_id,
          status: "applied",
          payment_operation_id: payment_operation_id,
          group_id: group.group_id,
          charged_back_cents: total,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        }
    end
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    Repo.all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id
    )
    |> Enum.each(fn entitlement ->
      unrecalled = entitlement.amount_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, unrecalled)

      lot
      |> change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecalled - removed
      )
      |> Repo.update!()

      entitlement
      |> change(revoked_cents: entitlement.amount_cents)
      |> Repo.update!()
    end)
  end

  defp payment_target(operation, operation_id, invalid_target_code) do
    payment_operation_id = Map.get(operation, "payment_operation_id")

    if valid_identifier?(payment_operation_id) do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          reject_and_rollback({"operation_not_found", %{}, operation_id})

        record ->
          result = Jason.decode!(record.result_json)

          if record.operation_type == "record_cash_payment" and result["status"] == "applied" do
            case Repo.get_by(Group, group_id: result["group_id"]) do
              %Group{} = group -> {:ok, record, result, group}
              _ -> reject_and_rollback({invalid_target_code, %{}, operation_id})
            end
          else
            reject_and_rollback({invalid_target_code, %{}, operation_id})
          end
      end
    else
      reject_and_rollback({"operation_not_found", %{}, operation_id})
    end
  end

  defp cash_allocations_for_payment(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        order_by: [asc: allocation.allocation_order, asc: allocation.id]
    )
  end

  defp payment_recorded_cents(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> 0
      record -> Jason.decode!(record.result_json)["amount_cents"] || 0
    end
  end

  defp reconcile_payment(record, payment_operation_id) do
    result = Jason.decode!(record.result_json)

    if record.operation_type != "record_cash_payment" or result["status"] != "applied" do
      {:error, :payment_not_reconcilable}
    else
      allocations = cash_allocations_for_payment(payment_operation_id)

      reconciliation = %{
        payment_operation_id: payment_operation_id,
        original_group_id: result["group_id"],
        recorded_cents: result["amount_cents"],
        held_cents: sum_disposition(allocations, "held"),
        refunded_cents: sum_disposition(allocations, "refunded"),
        retained_cents: sum_disposition(allocations, "retained"),
        converted_to_credit_cents: sum_disposition(allocations, "converted"),
        reduced_cents: sum_disposition(allocations, "reduced"),
        charged_back_cents: sum_disposition(allocations, "charged_back")
      }

      if Enum.any?(allocations, & &1.transferred) do
        {:ok, Map.put(reconciliation, :held_by_group, held_cash_by_group(payment_operation_id))}
      else
        {:ok, reconciliation}
      end
    end
  end

  defp sum_disposition(allocations, disposition) do
    allocations
    |> Enum.filter(&(&1.disposition == disposition))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        join: group in Group,
        on: group.id == allocation.group_record_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == "held",
        group_by: group.group_id,
        order_by: group.group_id,
        select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp requested_room_ids(room_ids) when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &valid_identifier?/1) and
         length(Enum.uniq(room_ids)) == length(room_ids) do
      {:ok, room_ids}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp requested_room_ids(_room_ids), do: {:error, "invalid_rooms"}

  defp active_requested_rooms(group_record_id, room_ids) do
    rooms =
      Repo.all(
        from room in GroupRoom,
          where: room.group_record_id == ^group_record_id and room.status == "active",
          order_by: [asc: room.position, asc: room.id]
      )

    if Enum.all?(room_ids, &Enum.any?(rooms, fn room -> room.room_id == &1 end)) do
      {:ok, Enum.filter(rooms, &(&1.room_id in room_ids))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp held_cash_allocations(room_ids) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.disposition == "held",
        order_by: [asc: allocation.id]
    )
  end

  defp sort_cash_allocations_by_funding_order(allocations) do
    Enum.sort_by(allocations, &{&1.allocation_order, &1.id})
  end

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Enum.filter(&(Date.compare(&1.expires_on, occurred_on) == :gt))
  end

  defp enough_credit(lots, amount_cents) do
    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) >= amount_cents do
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  defp allocate_cash(group, operation_id, amount_cents) do
    capacities = funding_capacities(group.id)
    {parts, _capacities, _remaining} = take_capacity(capacities, amount_cents)

    Enum.each(parts, fn {room, amount} ->
      %CashAllocation{}
      |> CashAllocation.changeset(%{
        group_record_id: group.id,
        group_room_id: room.id,
        payment_operation_id: operation_id,
        amount_cents: amount,
        disposition: "held",
        allocation_order: next_allocation_order(),
        transferred: false
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_credit(group, operation_id, lots, amount_cents) do
    capacities = funding_capacities(group.id)

    Enum.reduce(lots, {capacities, amount_cents}, fn lot, {capacities, remaining} ->
      requested = min(lot.remaining_cents, remaining)
      {parts, capacities, used} = take_capacity(capacities, requested)

      Enum.each(parts, fn {room, amount} ->
        %GroupCreditAllocation{}
        |> GroupCreditAllocation.changeset(%{
          group_record_id: group.id,
          group_room_id: room.id,
          credit_lot_id: lot.id,
          amount_cents: amount,
          source_operation_id: operation_id,
          status: "held",
          allocation_order: next_allocation_order()
        })
        |> Repo.insert!()
      end)

      lot
      |> change(remaining_cents: lot.remaining_cents - used)
      |> Repo.update!()

      {capacities, remaining - used}
    end)

    :ok
  end

  defp move_deposit_allocations(source_group_record_id, destination_group_record_id, amount_cents) do
    source_allocations = held_allocations(source_group_record_id)
    capacities = funding_capacities(destination_group_record_id)

    Enum.reduce_while(source_allocations, {capacities, amount_cents}, fn {kind, allocation},
                                                                         {capacities, remaining} ->
      requested = min(allocation.amount_cents, remaining)
      {parts, capacities, moved} = take_capacity(capacities, requested)

      move_allocation(kind, allocation, destination_group_record_id, parts, moved)

      remaining = remaining - moved
      if remaining == 0, do: {:halt, {capacities, 0}}, else: {:cont, {capacities, remaining}}
    end)

    :ok
  end

  defp held_allocations(group_record_id) do
    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where:
            allocation.group_record_id == ^group_record_id and
              allocation.disposition == "held" and room.status == "active",
          select: allocation
      )
      |> Enum.map(&{:cash, &1})

    credit_allocations =
      Repo.all(
        from allocation in GroupCreditAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where:
            allocation.group_record_id == ^group_record_id and
              allocation.status == "held" and room.status == "active",
          select: allocation
      )
      |> Enum.map(&{:credit, &1})

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(
      fn {_kind, allocation} -> {allocation.allocation_order, allocation.id} end,
      :desc
    )
  end

  defp move_allocation(_kind, _allocation, _destination_group_record_id, [], 0), do: :ok

  defp move_allocation(
         :cash,
         allocation,
         destination_group_record_id,
         [{first_room, first_amount} | remaining_parts],
         moved
       ) do
    remaining_amount = allocation.amount_cents - moved

    if remaining_amount > 0 do
      allocation
      |> change(amount_cents: remaining_amount, transferred: true)
      |> Repo.update!()

      insert_moved_cash_allocation(
        allocation,
        destination_group_record_id,
        first_room.id,
        first_amount
      )
    else
      allocation
      |> change(
        group_record_id: destination_group_record_id,
        group_room_id: first_room.id,
        allocation_order: next_allocation_order(),
        transferred: true
      )
      |> Repo.update!()
    end

    Enum.each(remaining_parts, fn {room, amount} ->
      insert_moved_cash_allocation(allocation, destination_group_record_id, room.id, amount)
    end)
  end

  defp move_allocation(
         :credit,
         allocation,
         destination_group_record_id,
         [{first_room, first_amount} | remaining_parts],
         moved
       ) do
    remaining_amount = allocation.amount_cents - moved

    if remaining_amount > 0 do
      allocation
      |> change(amount_cents: remaining_amount)
      |> Repo.update!()

      insert_moved_credit_allocation(
        allocation,
        destination_group_record_id,
        first_room.id,
        first_amount
      )
    else
      allocation
      |> change(
        group_record_id: destination_group_record_id,
        group_room_id: first_room.id,
        allocation_order: next_allocation_order()
      )
      |> Repo.update!()
    end

    Enum.each(remaining_parts, fn {room, amount} ->
      insert_moved_credit_allocation(allocation, destination_group_record_id, room.id, amount)
    end)
  end

  defp insert_moved_cash_allocation(allocation, group_record_id, room_id, amount_cents) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      group_record_id: group_record_id,
      group_room_id: room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount_cents,
      disposition: "held",
      allocation_order: next_allocation_order(),
      transferred: true
    })
    |> Repo.insert!()
  end

  defp insert_moved_credit_allocation(allocation, group_record_id, room_id, amount_cents) do
    %GroupCreditAllocation{}
    |> GroupCreditAllocation.changeset(%{
      group_record_id: group_record_id,
      group_room_id: room_id,
      credit_lot_id: allocation.credit_lot_id,
      amount_cents: amount_cents,
      source_operation_id: allocation.source_operation_id,
      status: "held",
      allocation_order: next_allocation_order()
    })
    |> Repo.insert!()
  end

  defp funding_capacities(group_record_id) do
    rooms_with_balances(group_record_id)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(fn room ->
      {room, max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)}
    end)
  end

  defp take_capacity(capacities, amount), do: take_capacity(capacities, amount, [], 0)

  defp take_capacity(capacities, amount, parts, used) when amount <= 0,
    do: {Enum.reverse(parts), capacities, used}

  defp take_capacity([{room, capacity} | rest], amount, parts, used) do
    allocated = min(capacity, amount)

    if allocated > 0 do
      take_capacity(
        [{room, capacity - allocated} | rest],
        amount - allocated,
        [{room, allocated} | parts],
        used + allocated
      )
    else
      take_capacity(rest, amount, parts, used)
    end
  end

  defp take_capacity([], amount, parts, used), do: {Enum.reverse(parts), [], used + 0 * amount}

  defp held_funding(group_record_id) do
    cash =
      Repo.one(
        from allocation in CashAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where:
            allocation.group_record_id == ^group_record_id and
              allocation.disposition == "held" and room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    credit =
      Repo.one(
        from allocation in GroupCreditAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where:
            allocation.group_record_id == ^group_record_id and
              allocation.status == "held" and room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    cash + credit
  end

  defp next_allocation_order do
    cash_max =
      Repo.one(from allocation in CashAllocation, select: max(allocation.allocation_order)) || 0

    credit_max =
      Repo.one(from allocation in GroupCreditAllocation, select: max(allocation.allocation_order)) ||
        0

    max(cash_max, credit_max) + 1
  end

  defp outstanding_deposit(group) do
    totals = active_accounting_totals(group.id)
    max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
  end

  defp active_accounting_totals(group_record_id) do
    rooms = rooms_with_balances(group_record_id) |> Enum.filter(&(&1.status == "active"))
    cash = Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2))
    credit = Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2))

    %{
      deposit_due_cents: Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2)),
      deposit_paid_cents: cash + credit
    }
  end

  defp rooms_with_balances(group_record_id) do
    rooms =
      Repo.all(
        from room in GroupRoom,
          where: room.group_record_id == ^group_record_id,
          order_by: [asc: room.position, asc: room.id]
      )

    cash_by_room =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_record_id == ^group_record_id,
          where: allocation.disposition in ^@cash_visible_dispositions,
          group_by: allocation.group_room_id,
          select: {allocation.group_room_id, coalesce(sum(allocation.amount_cents), 0)}
      )
      |> Map.new()

    credit_by_room =
      Repo.all(
        from allocation in GroupCreditAllocation,
          where: allocation.group_record_id == ^group_record_id,
          group_by: allocation.group_room_id,
          select: {allocation.group_room_id, coalesce(sum(allocation.amount_cents), 0)}
      )
      |> Map.new()

    Enum.map(rooms, fn room ->
      %{
        room
        | cash_paid_cents: Map.get(cash_by_room, room.id, 0),
          credit_paid_cents: Map.get(credit_by_room, room.id, 0)
      }
    end)
  end

  defp sync_group!(group, attrs \\ %{}) do
    balances = rooms_with_balances(group.id)

    Enum.each(balances, fn room ->
      room
      |> change(cash_paid_cents: room.cash_paid_cents, credit_paid_cents: room.credit_paid_cents)
      |> Repo.update!()
    end)

    active_rooms = Enum.filter(balances, &(&1.status == "active"))
    cash_paid = Enum.reduce(active_rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid = Enum.reduce(active_rooms, 0, &(&1.credit_paid_cents + &2))

    group
    |> change(
      Map.merge(attrs, %{
        deposit_paid_cents: cash_paid + credit_paid,
        cash_paid_cents: cash_paid,
        credit_paid_cents: credit_paid,
        revision: group.revision + 1
      })
    )
    |> Repo.update!()
  end

  defp sync_groups_after_cash_change(group, changes, default, attrs_builder) do
    group_ids = [group.id | Map.keys(changes)] |> Enum.uniq()

    Enum.reduce(group_ids, group, fn group_id, original_group ->
      current_group = if group_id == group.id, do: group, else: Repo.get!(Group, group_id)
      value = Map.get(changes, group_id, default)
      updated_group = sync_group!(current_group, attrs_builder.(current_group, value))

      if group_id == group.id, do: updated_group, else: original_group
    end)
  end

  defp add_cash_disposition_change(attrs, "refunded", amount),
    do: Map.update(attrs, :refunded_delta, -amount, &(&1 - amount))

  defp add_cash_disposition_change(attrs, "retained", amount),
    do: Map.update(attrs, :retained_delta, -amount, &(&1 - amount))

  defp add_cash_disposition_change(attrs, "converted", amount),
    do: Map.update(attrs, :converted_delta, -amount, &(&1 - amount))

  defp add_cash_disposition_change(attrs, _disposition, _amount), do: attrs

  defp update_group!(group, attrs) do
    group
    |> change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp validate_open(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rate_plan} <- valid_rate_plan(Map.get(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(Map.get(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)

      with {:ok, lodging_total_cents} <- lodging_total(rooms, nights) do
        deposit_due_cents = calculate_deposit(rooms, nights, rate_plan)

        {:ok,
         %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           policy_version: CancellationPolicy.version(rate_plan, booked_on),
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_to_credit_cents: 0,
           cash_reduced_cents: 0,
           cash_charged_back_cents: 0,
           rooms: rooms
         }}
      end
    else
      false -> {:error, "invalid_stay"}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {room, position}, {:ok, ids, valid_rooms} ->
      with {:ok, room_id} <- required_identifier(room, "room_id"),
           {:ok, nightly_rate_cents} <- valid_rate(room, "nightly_rate_cents"),
           false <- MapSet.member?(ids, room_id) do
        {:cont,
         {:ok, MapSet.put(ids, room_id),
          [
            %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
            | valid_rooms
          ]}}
      else
        true -> {:halt, {:error, "invalid_rooms"}}
        {:error, _code} -> {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, rooms_in_reverse_order} -> {:ok, Enum.reverse(rooms_in_reverse_order)}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp lodging_total(rooms, nights) do
    Enum.reduce_while(rooms, {:ok, 0}, fn room, {:ok, total} ->
      room_total = room.nightly_rate_cents * nights
      new_total = total + room_total

      if room_total <= @max_sqlite_integer and new_total <= @max_sqlite_integer do
        {:cont, {:ok, new_total}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
  end

  defp calculate_deposit(rooms, nights, @advance_purchase_rate_plan),
    do: Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))

  defp calculate_deposit(rooms, nights, @flexible_rate_plan) do
    Enum.reduce(rooms, 0, &(round_half_up(&1.nightly_rate_cents * nights * 20, 100) + &2))
  end

  defp insert_rooms(group, rooms) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      changeset =
        GroupRoom.changeset(%GroupRoom{}, %{
          group_record_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: room.position,
          deposit_due_cents: room_deposit(group.rate_plan, room.nightly_rate_cents, nights),
          status: "active",
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })

      case Repo.insert(changeset) do
        {:ok, _room} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, :invalid_rooms}}
      end
    end)
  end

  defp room_deposit(@advance_purchase_rate_plan, nightly_rate_cents, nights),
    do: nightly_rate_cents * nights

  defp room_deposit(@flexible_rate_plan, nightly_rate_cents, nights),
    do: round_half_up(nightly_rate_cents * nights * 20, 100)

  defp valid_rate_plan(@flexible_rate_plan), do: {:ok, @flexible_rate_plan}
  defp valid_rate_plan(@advance_purchase_rate_plan), do: {:ok, @advance_purchase_rate_plan}
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp valid_rate(room, key) when is_map(room) do
    case Map.get(room, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_operation, _key), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    case parse_date(Map.get(operation, key)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp usable_amount(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp usable_amount(_value), do: {:error, "invalid_amount"}

  defp refundable?(group, occurred_on) do
    CancellationPolicy.refundable?(group.policy_version, group.arrival_on, occurred_on)
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_refund_method"}
    end
  end

  defp available_refund_method("cash", _refundable), do: :ok
  defp available_refund_method("hotel_credit", true), do: :ok

  defp available_refund_method("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp credit_value(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp round_half_up(numerator, denominator),
    do: div(numerator * 2 + denominator, denominator * 2)

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp rejected(operation_id, code, details \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, details)

  defp reject(operation_id, code, details \\ %{}),
    do: reject_and_rollback({code, details, operation_id})

  defp reject_and_rollback(code) do
    {code, details, operation_id} = normalize_rejection(code)
    throw({:group_stay_rejected, rejected(operation_id, code, details)})
  end

  defp normalize_rejection({code, details, operation_id}), do: {code, details, operation_id}
  defp normalize_rejection(code), do: {code, %{}, nil}
end
