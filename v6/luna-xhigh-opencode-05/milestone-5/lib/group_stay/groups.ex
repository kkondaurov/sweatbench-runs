defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{
    CashAllocation,
    CashPayment,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    LegacyCashFunding,
    OperationRecord,
    Room
  }

  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"

  @doc """
  Applies a partner batch in order. Each operation has its own transaction so a
  rejected operation cannot undo an earlier operation in the same batch.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, serialize_group(load_rooms(group))}
    end
  end

  def get_group(_group_id), do: :not_found

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, Jason.decode!(operation.result)}
    end
  end

  def get_operation(_operation_id), do: :not_found

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %OperationRecord{operation_type: "record_cash_payment", result: result} ->
        result = Jason.decode!(result)

        if result["status"] == "applied" do
          case Repo.get(CashPayment, payment_operation_id) do
            nil -> {:error, :not_reconcilable}
            payment -> {:ok, serialize_payment(payment)}
          end
        else
          {:error, :not_reconcilable}
        end

      _operation ->
        {:error, :not_reconcilable}
    end
  end

  def get_payment(_payment_operation_id), do: :not_found

  def ledger(on_date \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          "cash_held_cents" => cash_total(:held_cents) + legacy_cash_total(:held_cents),
          "cash_refunded_cents" =>
            cash_total(:refunded_cents) + legacy_cash_total(:refunded_cents),
          "cash_retained_cents" =>
            cash_total(:retained_cents) + legacy_cash_total(:retained_cents),
          "cash_converted_to_credit_cents" =>
            cash_total(:converted_to_credit_cents) +
              legacy_cash_total(:converted_to_credit_cents),
          "cash_reduced_cents" => cash_total(:reduced_cents),
          "cash_charged_back_cents" => cash_total(:charged_back_cents),
          "credit_liability_cents" => credit_liability(on_date),
          "credit_shortfall_cents" => credit_shortfall(on_date)
        }
      end)

    totals
  end

  def guest_credit(guest_id, on_date \\ Date.utc_today())

  def guest_credit(guest_id, on_date) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on_date and
              lot.expires_on >= ^on_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      "lots" => Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  def guest_credit(guest_id, _on_date) do
    %{"guest_id" => guest_id, "available_cents" => 0, "lots" => []}
  end

  defp process_operation(operation) do
    case Repo.transaction(fn -> process_operation_in_transaction(operation) end, mode: :immediate) do
      {:ok, result} -> result
    end
  end

  defp process_operation_in_transaction(operation) do
    case operation_id(operation) do
      {:ok, operation_id} ->
        payload = canonical_json(operation)

        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil ->
            result = execute_in_savepoint(operation)
            persist_operation!(operation, operation_id, payload, result)
            result

          %OperationRecord{payload: ^payload, result: stored_result} ->
            Jason.decode!(stored_result)

          %OperationRecord{} ->
            result(operation, "rejected")
            |> Map.put("code", "operation_id_conflict")
        end

      :error ->
        execute_in_savepoint(operation)
    end
  end

  defp execute_in_savepoint(operation) do
    Repo.query!("SAVEPOINT operation_domain")

    case execute_operation(operation) do
      {:rejected, result} ->
        Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
        Repo.query!("RELEASE SAVEPOINT operation_domain")
        result

      {:applied, result} ->
        Repo.query!("RELEASE SAVEPOINT operation_domain")
        result
    end
  end

  defp execute_operation(operation) when is_map(operation) do
    case field(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp execute_operation(_operation), do: reject(%{}, "invalid_operation")

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         :ok <- ensure_group_missing(group_id),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on"), "invalid_stay"),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on"), "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      stay_length = Date.diff(departure_on, arrival_on)
      lodging_total_cents = calculate_lodging(rooms, stay_length)
      deposit_due_cents = calculate_deposit(rooms, rate_plan, stay_length)
      policy_version = policy_version(rate_plan, occurred_on)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
        status: @active,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      room_attrs =
        Enum.map(rooms, fn room ->
          lodging_cents = room.nightly_rate_cents * stay_length

          %{
            group_id: group_id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            status: @active,
            lodging_cents: lodging_cents,
            deposit_due_cents: room_deposit(room, rate_plan, stay_length),
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end)

      case insert_group(attrs, room_attrs) do
        :ok ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           })}

        :already_exists ->
          reject(operation, "group_already_exists")

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_payment_amount(amount_cents, group) do
      rooms = load_rooms(group).rooms
      allocate_cash_funding(group, rooms, amount_cents, field(operation, "operation_id"))

      insert_cash_payment!(%{
        payment_operation_id: field(operation, "operation_id"),
        original_group_id: group.group_id,
        recorded_cents: amount_cents,
        held_cents: amount_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      })

      updated_group = refresh_group(group, %{revision: group.revision + 1})

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "group_id" => group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding(updated_group),
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_hotel_credit(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_payment_amount(amount_cents, group),
         {:ok, lots} <- available_credit_lots(group.guest_id, amount_cents, occurred_on) do
      allocation_plan = build_allocation_plan(lots, amount_cents)

      allocate_credit_funding(
        group,
        allocation_plan,
        amount_cents,
        field(operation, "operation_id")
      )

      updated_group = refresh_group(group, %{revision: group.revision + 1})

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "group_id" => group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding(updated_group),
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- validate_common(operation),
         {:ok, source_group_id} <- required_identifier(operation, "source_group_id"),
         {:ok, source_group} <- transfer_group(source_group_id),
         {:ok, destination_group_id} <- required_identifier(operation, "destination_group_id"),
         {:ok, destination_group} <- transfer_group(destination_group_id),
         :ok <- check_revision(operation, source_group),
         :ok <- check_revision(operation, destination_group, "destination_expected_revision"),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         :ok <- validate_transfer_groups(source_group, destination_group),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_transfer_funding(source_group, amount_cents),
         :ok <- validate_transfer_outstanding(destination_group, amount_cents) do
      allocations = held_allocations(source_group.group_id)
      transfer_allocation_chunks!(destination_group, allocations, amount_cents)

      updated_source = refresh_group(source_group, %{revision: source_group.revision + 1})

      updated_destination =
        refresh_group(destination_group, %{revision: destination_group.revision + 1})

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "source_group_id" => source_group.group_id,
         "destination_group_id" => destination_group.group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => outstanding(updated_source),
         "destination_outstanding_deposit_cents" => outstanding(updated_destination),
         "source_revision" => updated_source.revision,
         "destination_revision" => updated_destination.revision
       })}
    else
      {:error, {:group_not_found, group_id}} ->
        reject_with_group(operation, "group_not_found", group_id)

      {:error, {:group_not_active, group_id}} ->
        reject_with_group(operation, "group_not_active", group_id)

      {:error, {:stale_revision, stale_result}} ->
        reject(operation, {:stale_revision, stale_result})

      {:error, code} ->
        reject(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on"), "invalid_stay"),
         :ok <- validate_rescheduled_stay(occurred_on, new_arrival_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      updated_group = %{
        group
        | arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
      }

      case update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival_on),
             "new_departure_on" => Date.to_iso8601(new_departure_on),
             "policy_version" => policy_version(group),
             "refundable_until" =>
               refundable_until(%{
                 group
                 | arrival_on: new_arrival_on,
                   policy_version: policy_version(group)
               }),
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, settlement_policy} <- cancellation_policy(group, occurred_on, refund_method) do
      rooms = load_rooms(group).rooms |> Enum.filter(&(&1.status == @active))

      settlement_policy =
        Map.put(settlement_policy, :operation_id, field(operation, "operation_id"))

      {:ok, updated_group, settlement} =
        settle_rooms(group, rooms, occurred_on, settlement_policy)

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "group_id" => group_id,
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_rooms(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, rooms} <- selected_active_rooms(group, field(operation, "room_ids")),
         {:ok, settlement_policy} <- cancellation_policy(group, occurred_on, refund_method) do
      settlement_policy =
        Map.put(settlement_policy, :operation_id, field(operation, "operation_id"))

      {:ok, updated_group, settlement} =
        settle_rooms(group, rooms, occurred_on, settlement_policy)

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "group_id" => group_id,
         "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reduce_cash_payment(operation) do
    with :ok <- validate_common(operation),
         {:ok, payment, group} <- target_payment(operation),
         :ok <- check_revision(operation, group),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_reducible(payment),
         :ok <- validate_reduction_amount(payment, amount_cents) do
      affected_group_ids = remove_cash_allocations(payment.payment_operation_id, amount_cents)

      payment =
        update_cash_payment!(payment, %{
          held_cents: payment.held_cents - amount_cents,
          reduced_cents: payment.reduced_cents + amount_cents
        })

      updated_groups = refresh_changed_groups(group, affected_group_ids)
      updated_group = Map.fetch!(updated_groups, group.group_id)

      _ = payment

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "payment_operation_id" => payment.payment_operation_id,
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding(updated_group),
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp charge_back_payment(operation) do
    with :ok <- validate_common(operation),
         {:ok, payment, group} <- target_payment(operation, "payment_not_chargeable"),
         :ok <- check_revision(operation, group),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         :ok <- validate_chargeable(payment) do
      charged_back_cents =
        payment.held_cents + payment.refunded_cents + payment.retained_cents +
          payment.converted_to_credit_cents

      affected_group_ids =
        remove_cash_allocations(payment.payment_operation_id, payment.held_cents)

      revoke_credit_entitlements(payment.payment_operation_id)

      update_cash_payment!(payment, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + charged_back_cents
      })

      updated_groups =
        refresh_changed_groups(group, affected_group_ids, %{
          refunded_cents: max(group.refunded_cents - payment.refunded_cents, 0),
          retained_cents: max(group.retained_cents - payment.retained_cents, 0),
          cash_converted_to_credit_cents:
            max(group.cash_converted_to_credit_cents - payment.converted_to_credit_cents, 0)
        })

      updated_group = Map.fetch!(updated_groups, group.group_id)

      {:applied,
       result(operation, "applied")
       |> Map.merge(%{
         "payment_operation_id" => payment.payment_operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => outstanding(updated_group),
         "revision" => updated_group.revision
       })}
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp target_payment(operation, invalid_code \\ "payment_not_reducible") do
    case field(operation, "payment_operation_id") do
      payment_operation_id when is_binary(payment_operation_id) and payment_operation_id != "" ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil ->
            {:error, "operation_not_found"}

          record ->
            result = Jason.decode!(record.result)

            case {record.operation_type, result["status"], result["group_id"],
                  Repo.get(CashPayment, payment_operation_id)} do
              {"record_cash_payment", "applied", group_id, %CashPayment{} = payment} ->
                case existing_group(group_id) do
                  {:ok, group} -> {:ok, payment, group}
                  {:error, code} -> {:error, code}
                end

              _ ->
                {:error, invalid_code}
            end
        end

      _ ->
        {:error, "operation_not_found"}
    end
  end

  defp validate_reducible(%CashPayment{held_cents: held_cents}) when held_cents > 0, do: :ok
  defp validate_reducible(_payment), do: {:error, "payment_not_reducible"}

  defp validate_reduction_amount(payment, amount_cents) do
    if amount_cents <= payment.held_cents do
      :ok
    else
      {:error, "reduction_exceeds_held_cash"}
    end
  end

  defp validate_chargeable(%CashPayment{} = payment) do
    cond do
      payment.charged_back_cents > 0 -> {:error, "payment_not_chargeable"}
      payment.recorded_cents - payment.reduced_cents <= 0 -> {:error, "payment_not_chargeable"}
      true -> :ok
    end
  end

  defp settle_rooms(group, rooms, occurred_on, settlement_policy) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_allocations = cash_allocations_for_rooms(group.group_id, room_ids)
    credit_allocations = credit_allocations_for_rooms(group.group_id, room_ids)
    cash_amount = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    settlement = %{
      refundable: settlement_policy.refundable,
      refunded_cents: if(settlement_policy.disposition == :refunded, do: cash_amount, else: 0),
      retained_cents: if(settlement_policy.disposition == :retained, do: cash_amount, else: 0),
      converted_cents: if(settlement_policy.disposition == :converted, do: cash_amount, else: 0),
      credit_issued_cents: 0
    }

    Enum.each(cash_allocations, fn allocation ->
      settle_cash_allocation(allocation, settlement_policy.disposition)
    end)

    if settlement_policy.refundable do
      restore_credit_allocations(credit_allocations, occurred_on)
    else
      Enum.each(credit_allocations, fn {allocation, _lot} -> Repo.delete!(allocation) end)
    end

    settlement =
      if settlement.converted_cents > 0 do
        credit_issued_cents =
          settlement.converted_cents + round_percentage(settlement.converted_cents, 10, 100)

        lot =
          insert_credit_lot!(%{
            guest_id: group.guest_id,
            source_operation_id: settlement_policy.operation_id,
            remaining_cents: credit_issued_cents,
            issued_on: occurred_on,
            expires_on: Date.add(occurred_on, 365),
            unrecovered_clawback_cents: 0
          })

        insert_credit_entitlements(lot, cash_contributions(cash_allocations))
        %{settlement | credit_issued_cents: credit_issued_cents}
      else
        settlement
      end

    Enum.each(rooms, fn room ->
      cash_removed =
        cash_allocations
        |> Enum.filter(&(&1.room_id == room.id))
        |> Enum.reduce(0, &(&1.amount_cents + &2))

      credit_removed =
        credit_allocations
        |> Enum.filter(fn {allocation, _lot} -> allocation.room_id == room.id end)
        |> Enum.reduce(0, fn {allocation, _lot}, total -> total + allocation.amount_cents end)

      update_room!(room, %{
        status: @cancelled,
        cash_paid_cents: max(room.cash_paid_cents - cash_removed, 0),
        credit_paid_cents: max(room.credit_paid_cents - credit_removed, 0)
      })
    end)

    active_remaining? =
      Repo.exists?(
        from room in Room, where: room.group_id == ^group.group_id and room.status == ^@active
      )

    changes = %{
      status: if(active_remaining?, do: @active, else: @cancelled),
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_cents,
      revision: group.revision + 1
    }

    {:ok, refresh_group(group, changes), settlement}
  end

  defp cancellation_policy(group, occurred_on, refund_method) do
    refundable = refundable?(group, occurred_on)

    case {refundable, refund_method} do
      {false, :hotel_credit} ->
        {:error, "refund_method_not_available"}

      {true, :cash} ->
        {:ok, %{refundable: true, disposition: :refunded, operation_id: nil}}

      {true, :hotel_credit} ->
        {:ok, %{refundable: true, disposition: :converted, operation_id: nil}}

      {false, :cash} ->
        {:ok, %{refundable: false, disposition: :retained, operation_id: nil}}
    end
  end

  defp settle_cash_allocation(allocation, disposition) do
    if allocation.payment_operation_id do
      payment = Repo.get!(CashPayment, allocation.payment_operation_id)

      changes =
        case disposition do
          :refunded ->
            %{
              held_cents: payment.held_cents - allocation.amount_cents,
              refunded_cents: payment.refunded_cents + allocation.amount_cents
            }

          :retained ->
            %{
              held_cents: payment.held_cents - allocation.amount_cents,
              retained_cents: payment.retained_cents + allocation.amount_cents
            }

          :converted ->
            %{
              held_cents: payment.held_cents - allocation.amount_cents,
              converted_to_credit_cents:
                payment.converted_to_credit_cents + allocation.amount_cents
            }
        end

      update_cash_payment!(payment, changes)
    else
      funding_group_id = allocation.legacy_funding_group_id || allocation.group_id
      funding = Repo.get!(LegacyCashFunding, funding_group_id)

      changes =
        case disposition do
          :refunded ->
            %{
              held_cents: funding.held_cents - allocation.amount_cents,
              refunded_cents: funding.refunded_cents + allocation.amount_cents
            }

          :retained ->
            %{
              held_cents: funding.held_cents - allocation.amount_cents,
              retained_cents: funding.retained_cents + allocation.amount_cents
            }

          :converted ->
            %{
              held_cents: funding.held_cents - allocation.amount_cents,
              converted_to_credit_cents:
                funding.converted_to_credit_cents + allocation.amount_cents
            }
        end

      update_legacy_cash!(funding, changes)
    end

    Repo.delete!(allocation)
  end

  defp restore_credit_allocations(credit_allocations, occurred_on) do
    credit_allocations
    |> Enum.group_by(fn {_allocation, lot} -> lot.id end)
    |> Enum.each(fn {_lot_id, allocations} ->
      {_allocation, lot} = hd(allocations)

      amount =
        Enum.reduce(allocations, 0, fn {allocation, _lot}, total ->
          total + allocation.amount_cents
        end)

      return_credit_to_lot!(lot, amount, occurred_on)
      Enum.each(allocations, fn {allocation, _lot} -> Repo.delete!(allocation) end)
    end)
  end

  defp return_credit_to_lot!(lot, amount, occurred_on) do
    unrecovered_clawback_cents = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered_clawback_cents, amount)
    excess = amount - absorbed

    remaining_cents =
      if Date.compare(lot.expires_on, occurred_on) == :lt do
        lot.remaining_cents
      else
        lot.remaining_cents + excess
      end

    update_credit_lot!(lot, %{
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: unrecovered_clawback_cents - absorbed
    })
  end

  defp selected_active_rooms(group, room_ids) when is_list(room_ids) do
    rooms = load_rooms(group).rooms

    cond do
      room_ids == [] ->
        {:error, "invalid_rooms"}

      length(Enum.uniq(room_ids)) != length(room_ids) ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, &(not valid_identifier?(&1))) ->
        {:error, "invalid_rooms"}

      true ->
        selected = Enum.filter(rooms, &(&1.room_id in room_ids and &1.status == @active))

        if length(selected) == length(room_ids) do
          {:ok, Enum.sort_by(selected, & &1.position)}
        else
          {:error, "invalid_rooms"}
        end
    end
  end

  defp selected_active_rooms(_group, _room_ids), do: {:error, "invalid_rooms"}

  defp cash_contributions(allocations) do
    allocations
    |> Enum.reduce([], fn allocation, contributions ->
      source = allocation.payment_operation_id

      case Enum.find_index(contributions, fn {existing_source, _amount} ->
             existing_source == source
           end) do
        nil ->
          contributions ++ [{source, allocation.amount_cents}]

        index ->
          List.update_at(contributions, index, fn {existing_source, amount} ->
            {existing_source, amount + allocation.amount_cents}
          end)
      end
    end)
  end

  defp insert_credit_entitlements(lot, contributions) do
    Enum.reduce(contributions, 0, fn {source, amount}, running ->
      next = running + amount
      entitlement = credit_value(next) - credit_value(running)

      if entitlement > 0 do
        Repo.insert!(
          CreditEntitlement.changeset(%CreditEntitlement{}, %{
            credit_lot_id: lot.id,
            payment_operation_id: source,
            amount_cents: entitlement
          })
        )
      end

      next
    end)
  end

  defp credit_value(amount), do: amount + round_percentage(amount, 10, 100)

  defp revoke_credit_entitlements(payment_operation_id) do
    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          join: lot in CreditLot,
          on: lot.id == entitlement.credit_lot_id,
          where: entitlement.payment_operation_id == ^payment_operation_id,
          select: {entitlement, lot}
      )

    Enum.each(entitlements, fn {entitlement, lot} ->
      removed = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered_clawback_cents = lot.unrecovered_clawback_cents || 0

      update_credit_lot!(lot, %{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          unrecovered_clawback_cents + (entitlement.amount_cents - removed)
      })
    end)
  end

  defp held_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.group_id == ^group_id,
          where: room.status == ^@active,
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.group_id == ^group_id,
          where: room.status == ^@active,
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )
      |> Enum.map(&%{kind: :credit, allocation: &1})

    Enum.sort_by(cash_allocations ++ credit_allocations, fn entry ->
      allocation = entry.allocation
      {-(allocation.allocation_order || 0), -allocation.id}
    end)
  end

  defp transfer_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp validate_transfer_groups(source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id ->
        {:error, "invalid_transfer"}

      source_group.guest_id != destination_group.guest_id ->
        {:error, "invalid_transfer"}

      source_group.status != @active ->
        {:error, {:group_not_active, source_group.group_id}}

      destination_group.status != @active ->
        {:error, {:group_not_active, destination_group.group_id}}

      true ->
        :ok
    end
  end

  defp validate_transfer_funding(source_group, amount_cents) do
    if amount_cents <= held_funding_cents(source_group.group_id) do
      :ok
    else
      {:error, "transfer_exceeds_held_funding"}
    end
  end

  defp validate_transfer_outstanding(destination_group, amount_cents) do
    if amount_cents <= outstanding(destination_group) do
      :ok
    else
      {:error, "transfer_exceeds_outstanding"}
    end
  end

  defp held_funding_cents(group_id) do
    held_allocations(group_id)
    |> Enum.reduce(0, fn entry, total -> total + entry.allocation.amount_cents end)
  end

  defp transfer_allocation_chunks!(destination_group, allocations, amount_cents) do
    {chunks, _remaining} =
      Enum.map_reduce(allocations, amount_cents, fn entry, remaining ->
        moved = min(entry.allocation.amount_cents, remaining)
        move_source_allocation!(entry, moved)
        {{entry, moved}, remaining - moved}
      end)

    allocate_transferred_chunks!(destination_group, chunks)

    chunks
    |> Enum.filter(fn {_entry, amount} -> amount > 0 end)
    |> Enum.flat_map(fn
      {%{kind: :cash, allocation: allocation}, _amount} -> [allocation.payment_operation_id]
      _entry -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      payment = Repo.get!(CashPayment, payment_operation_id)
      update_cash_payment!(payment, %{transfer_participated: true})
    end)
  end

  defp move_source_allocation!(_entry, amount) when amount <= 0, do: :ok

  defp move_source_allocation!(%{kind: :cash, allocation: allocation}, amount) do
    room = Repo.get!(Room, allocation.room_id)
    update_room!(room, %{cash_paid_cents: room.cash_paid_cents - amount})

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      update_cash_allocation!(allocation, %{amount_cents: allocation.amount_cents - amount})
    end
  end

  defp move_source_allocation!(%{kind: :credit, allocation: allocation}, amount) do
    room = Repo.get!(Room, allocation.room_id)
    update_room!(room, %{credit_paid_cents: room.credit_paid_cents - amount})

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      update_credit_allocation!(allocation, %{amount_cents: allocation.amount_cents - amount})
    end
  end

  defp allocate_transferred_chunks!(destination_group, chunks) do
    rooms = load_rooms(destination_group).rooms |> Enum.filter(&(&1.status == @active))

    Enum.reduce(chunks, rooms, fn {entry, amount}, rooms ->
      {rooms, remaining} =
        Enum.map_reduce(rooms, amount, fn room, remaining ->
          capacity =
            max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

          allocated = min(capacity, remaining)

          if allocated > 0 do
            insert_transferred_allocation!(destination_group, room, entry, allocated)

            changes =
              case entry.kind do
                :cash -> %{cash_paid_cents: room.cash_paid_cents + allocated}
                :credit -> %{credit_paid_cents: room.credit_paid_cents + allocated}
              end

            update_room!(room, changes)
          end

          room =
            case entry.kind do
              :cash -> %{room | cash_paid_cents: room.cash_paid_cents + allocated}
              :credit -> %{room | credit_paid_cents: room.credit_paid_cents + allocated}
            end

          {room, remaining - allocated}
        end)

      if remaining != 0, do: raise("transfer destination capacity changed")
      rooms
    end)

    :ok
  end

  defp insert_transferred_allocation!(destination_group, room, entry, amount) do
    allocation_order = next_allocation_order!()

    attrs =
      case entry.kind do
        :cash ->
          %{
            group_id: destination_group.group_id,
            room_id: room.id,
            payment_operation_id: entry.allocation.payment_operation_id,
            legacy_funding_group_id:
              entry.allocation.legacy_funding_group_id || entry.allocation.group_id,
            amount_cents: amount,
            allocation_order: allocation_order
          }

        :credit ->
          %{
            group_id: destination_group.group_id,
            credit_lot_id: entry.allocation.credit_lot_id,
            room_id: room.id,
            amount_cents: amount,
            funding_operation_id: entry.allocation.funding_operation_id,
            allocation_order: allocation_order
          }
      end

    case entry.kind do
      :cash -> Repo.insert!(CashAllocation.changeset(%CashAllocation{}, attrs))
      :credit -> Repo.insert!(CreditAllocation.changeset(%CreditAllocation{}, attrs))
    end
  end

  defp remove_cash_allocations(_payment_operation_id, amount) when amount <= 0, do: []

  defp remove_cash_allocations(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )

    {_remaining, affected_group_ids} =
      Enum.reduce(allocations, {amount, MapSet.new()}, fn allocation, {remaining, group_ids} ->
        if remaining == 0 do
          {remaining, group_ids}
        else
          removed = min(allocation.amount_cents, remaining)
          room = Repo.get!(Room, allocation.room_id)
          update_room!(room, %{cash_paid_cents: room.cash_paid_cents - removed})

          if removed == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            update_cash_allocation!(allocation, %{amount_cents: allocation.amount_cents - removed})
          end

          {remaining - removed, MapSet.put(group_ids, allocation.group_id)}
        end
      end)

    MapSet.to_list(affected_group_ids)
  end

  defp cash_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: [asc: allocation.allocation_order, asc: allocation.id]
    )
  end

  defp credit_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in CreditAllocation,
        join: lot in CreditLot,
        on: lot.id == allocation.credit_lot_id,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: [asc: allocation.allocation_order, asc: allocation.id],
        select: {allocation, lot}
    )
  end

  defp allocate_cash_funding(group, rooms, amount, payment_operation_id) do
    rooms = Enum.filter(rooms, &(&1.status == @active))

    Enum.reduce_while(rooms, amount, fn room, remaining ->
      capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
      allocated = min(capacity, remaining)

      if allocated > 0 do
        Repo.insert!(
          CashAllocation.changeset(%CashAllocation{}, %{
            group_id: group.group_id,
            room_id: room.id,
            payment_operation_id: payment_operation_id,
            amount_cents: allocated,
            allocation_order: next_allocation_order!()
          })
        )

        update_room!(room, %{cash_paid_cents: room.cash_paid_cents + allocated})
      end

      remaining = remaining - allocated
      if remaining == 0, do: {:halt, 0}, else: {:cont, remaining}
    end)

    :ok
  end

  defp allocate_credit_funding(group, allocation_plan, amount, operation_id) do
    rooms = load_rooms(group).rooms |> Enum.filter(&(&1.status == @active))

    Enum.reduce(allocation_plan, {rooms, amount}, fn {lot, lot_amount},
                                                     {rooms, remaining_total} ->
      update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents - lot_amount})

      {rooms, _remaining_lot} =
        Enum.map_reduce(rooms, lot_amount, fn room, remaining_lot ->
          capacity =
            max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

          allocated = min(capacity, remaining_lot)

          if allocated > 0 do
            Repo.insert!(
              CreditAllocation.changeset(%CreditAllocation{}, %{
                group_id: group.group_id,
                credit_lot_id: lot.id,
                room_id: room.id,
                amount_cents: allocated,
                funding_operation_id: operation_id,
                allocation_order: next_allocation_order!()
              })
            )

            update_room!(room, %{credit_paid_cents: room.credit_paid_cents + allocated})
          end

          {%{room | credit_paid_cents: room.credit_paid_cents + allocated},
           remaining_lot - allocated}
        end)

      {rooms, remaining_total - lot_amount}
    end)

    :ok
  end

  defp insert_group(attrs, rooms) do
    changeset = Group.changeset(%Group{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _group} ->
        Enum.reduce_while(rooms, :ok, fn room, :ok ->
          case Repo.insert(Room.changeset(%Room{}, room)) do
            {:ok, _room} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, :error}
          end
        end)

      {:error, _changeset} ->
        :already_exists
    end
  end

  defp refresh_group(group, changes) do
    totals = active_room_totals(group.group_id)
    changes = Map.merge(totals, changes)

    {:ok, updated_group} = update_group(group, changes)
    updated_group
  end

  defp refresh_changed_groups(addressed_group, affected_group_ids, addressed_changes \\ %{}) do
    [addressed_group.group_id | affected_group_ids]
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn group_id, groups ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      changes =
        if group_id == addressed_group.group_id do
          addressed_changes
        else
          %{}
        end

      updated_group = refresh_group(group, Map.put(changes, :revision, group.revision + 1))
      Map.put(groups, group_id, updated_group)
    end)
  end

  defp active_room_totals(group_id) do
    {lodging, due, paid, cash, credit} =
      Repo.one(
        from room in Room,
          where: room.group_id == ^group_id and room.status == ^@active,
          select:
            {coalesce(sum(room.lodging_cents), 0), coalesce(sum(room.deposit_due_cents), 0),
             coalesce(sum(room.cash_paid_cents + room.credit_paid_cents), 0),
             coalesce(sum(room.cash_paid_cents), 0), coalesce(sum(room.credit_paid_cents), 0)}
      )

    %{
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      deposit_paid_cents: paid,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    }
  end

  defp update_group(group, changes) do
    case group |> Group.changeset(changes) |> Repo.update() do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, _changeset} -> :error
    end
  end

  defp update_room!(room, changes) do
    room |> Room.changeset(changes) |> Repo.update!()
  end

  defp update_cash_allocation!(allocation, changes) do
    allocation |> CashAllocation.changeset(changes) |> Repo.update!()
  end

  defp update_credit_allocation!(allocation, changes) do
    allocation |> CreditAllocation.changeset(changes) |> Repo.update!()
  end

  defp next_allocation_order! do
    cash_order =
      Repo.one(
        from allocation in CashAllocation, select: coalesce(max(allocation.allocation_order), 0)
      )

    credit_order =
      Repo.one(
        from allocation in CreditAllocation, select: coalesce(max(allocation.allocation_order), 0)
      )

    max(cash_order, credit_order) + 1
  end

  defp insert_cash_payment!(attrs) do
    attrs |> then(&CashPayment.changeset(%CashPayment{}, &1)) |> Repo.insert!()
  end

  defp update_cash_payment!(payment, changes) do
    payment |> CashPayment.changeset(changes) |> Repo.update!()
  end

  defp update_legacy_cash!(funding, changes) do
    funding |> LegacyCashFunding.changeset(changes) |> Repo.update!()
  end

  defp available_credit_lots(guest_id, amount_cents, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.issued_on <= ^occurred_on and lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp build_allocation_plan(lots, amount_cents) do
    {plan, _remaining} =
      Enum.map_reduce(lots, amount_cents, fn lot, remaining ->
        amount = min(lot.remaining_cents, remaining)
        {{lot, amount}, remaining - amount}
      end)

    Enum.reject(plan, fn {_lot, amount} -> amount == 0 end)
  end

  defp update_credit_lot!(lot, changes) do
    lot |> CreditLot.changeset(changes) |> Repo.update!()
  end

  defp insert_credit_lot!(attrs) do
    attrs |> then(&CreditLot.changeset(%CreditLot{}, &1)) |> Repo.insert!()
  end

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp validate_payment_amount(amount_cents, group) do
    if amount_cents <= outstanding(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp load_rooms(group) do
    %{
      group
      | rooms:
          Repo.all(
            from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
          )
    }
  end

  defp serialize_group(group) do
    active_rooms = Enum.filter(group.rooms, &(&1.status == @active))
    totals = room_totals(active_rooms)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until(%{group | policy_version: policy_version(group)}),
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &serialize_room/1),
      "lodging_total_cents" => totals.lodging_total_cents,
      "deposit_due_cents" => totals.deposit_due_cents,
      "deposit_paid_cents" => totals.deposit_paid_cents,
      "cash_paid_cents" => totals.cash_paid_cents,
      "credit_paid_cents" => totals.credit_paid_cents,
      "outstanding_deposit_cents" =>
        if(group.status == @active,
          do: max(totals.deposit_due_cents - totals.deposit_paid_cents, 0),
          else: 0
        )
    }
  end

  defp room_totals(rooms) do
    Enum.reduce(
      rooms,
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn room, totals ->
        %{
          totals
          | lodging_total_cents: totals.lodging_total_cents + room.lodging_cents,
            deposit_due_cents: totals.deposit_due_cents + room.deposit_due_cents,
            deposit_paid_cents:
              totals.deposit_paid_cents + room.cash_paid_cents + room.credit_paid_cents,
            cash_paid_cents: totals.cash_paid_cents + room.cash_paid_cents,
            credit_paid_cents: totals.credit_paid_cents + room.credit_paid_cents
        }
      end
    )
  end

  defp serialize_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "lodging_cents" => room.lodging_cents,
      "deposit_due_cents" => room.deposit_due_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end

  defp serialize_credit_lot(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp serialize_payment(payment) do
    statement = %{
      "payment_operation_id" => payment.payment_operation_id,
      "original_group_id" => payment.original_group_id,
      "recorded_cents" => payment.recorded_cents,
      "held_cents" => payment.held_cents,
      "refunded_cents" => payment.refunded_cents,
      "retained_cents" => payment.retained_cents,
      "converted_to_credit_cents" => payment.converted_to_credit_cents,
      "reduced_cents" => payment.reduced_cents,
      "charged_back_cents" => payment.charged_back_cents
    }

    if payment.transfer_participated do
      Map.put(statement, "held_by_group", held_cash_by_group(payment.payment_operation_id))
    else
      statement
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        group_by: allocation.group_id,
        order_by: allocation.group_id,
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp cash_total(field_name) do
    Repo.one(from payment in CashPayment, select: coalesce(sum(field(payment, ^field_name)), 0))
  end

  defp legacy_cash_total(field_name) do
    Repo.one(
      from funding in LegacyCashFunding, select: coalesce(sum(field(funding, ^field_name)), 0)
    )
  end

  defp credit_liability(on_date) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where:
            lot.remaining_cents > 0 and lot.issued_on <= ^on_date and lot.expires_on >= ^on_date,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == ^@active and lot.issued_on <= ^on_date,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp credit_shortfall(on_date) do
    CreditLot
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      issued_on = lot.issued_on || Date.add(lot.expires_on, -365)

      if Date.compare(issued_on, on_date) == :gt do
        total
      else
        applied =
          Repo.one(
            from allocation in CreditAllocation,
              join: group in Group,
              on: group.group_id == allocation.group_id,
              where: allocation.credit_lot_id == ^lot.id and group.status == ^@active,
              select: coalesce(sum(allocation.amount_cents), 0)
          )

        total + min(lot.unrecovered_clawback_cents || 0, applied)
      end
    end)
  end

  defp operation_id(operation) do
    case field(operation, "operation_id") do
      operation_id when is_binary(operation_id) and operation_id != "" -> {:ok, operation_id}
      _value -> :error
    end
  end

  defp persist_operation!(operation, operation_id, payload, result) do
    OperationRecord.changeset(%OperationRecord{}, %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload: payload,
      result: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  defp operation_type(operation) do
    case field(operation, "type") do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp canonical_json(value) do
    value
    |> canonical_json_value()
    |> Jason.encode!()
  end

  defp canonical_json_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {json_key(key), canonical_json_value(nested_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_json_value(value) when is_list(value),
    do: Enum.map(value, &canonical_json_value/1)

  defp canonical_json_value(value), do: value

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp result(operation, status),
    do: %{"operation_id" => field(operation, "operation_id"), "status" => status}

  defp reject(operation, code) when is_binary(code) do
    {:rejected, result(operation, "rejected") |> Map.put("code", code)}
  end

  defp reject(_operation, {:stale_revision, stale_result}), do: {:rejected, stale_result}

  defp reject_with_group(operation, code, group_id) do
    {:rejected,
     result(operation, "rejected")
     |> Map.merge(%{"code" => code, "group_id" => group_id})}
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp field(_map, _key), do: nil

  defp field_with_presence(map, key) when is_map(map) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:present, Map.get(map, atom_key)}
      true -> :absent
    end
  end

  defp field_with_presence(_map, _key), do: :absent

  defp validate_common(operation) do
    if valid_identifier?(field(operation, "operation_id")) and
         field(operation, "occurred_on") != nil do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp existing_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp ensure_group_missing(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      _group -> {:error, "group_already_exists"}
    end
  end

  defp check_revision(operation, group, revision_key \\ "expected_revision") do
    case field_with_presence(operation, revision_key) do
      :absent ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         {:stale_revision,
          %{
            "operation_id" => field(operation, "operation_id"),
            "status" => "rejected",
            "code" => "stale_revision",
            "group_id" => group.group_id,
            "expected_revision" => expected_revision,
            "actual_revision" => group.revision
          }}}
    end
  end

  defp validate_active(%Group{status: @active}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp parse_date(value, error_code) when is_binary(value),
    do: date_result(Date.from_iso8601(value), error_code)

  defp parse_date(%Date{} = value, _error_code), do: {:ok, value}
  defp parse_date(_value, error_code), do: {:error, error_code}

  defp date_result({:ok, date}, _error_code), do: {:ok, date}
  defp date_result({:error, _reason}, error_code), do: {:error, error_code}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rescheduled_stay(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp policy_version(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version(@flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: @flex_14, else: @flex_30
  end

  defp policy_version(%Group{policy_version: nil, rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp cancellation_window(@flex_14), do: 14
  defp cancellation_window(@flex_30), do: 30
  defp cancellation_window(@advance_nonrefundable), do: nil

  defp refundable?(%Group{} = group, occurred_on) do
    case cancellation_window(policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(%{policy_version: @advance_nonrefundable}), do: nil

  defp refundable_until(%{arrival_on: arrival_on, policy_version: policy_version}) do
    arrival_on |> Date.add(-cancellation_window(policy_version)) |> Date.to_iso8601()
  end

  defp refund_method(operation) do
    case field_with_presence(operation, "refund_method") do
      :absent -> {:ok, :cash}
      {:present, "cash"} -> {:ok, :cash}
      {:present, "hotel_credit"} -> {:ok, :hotel_credit}
      {:present, _value} -> {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, valid_rooms} ->
      case validate_room(room, position) do
        {:ok, valid_room} -> {:cont, {:ok, [valid_room | valid_rooms]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid_rooms} ->
        valid_rooms = Enum.reverse(valid_rooms)

        if length(Enum.uniq_by(valid_rooms, & &1.room_id)) == length(valid_rooms),
          do: {:ok, valid_rooms},
          else: {:error, "invalid_rooms"}

      error ->
        error
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_room(room, position) when is_map(room) do
    room_id = field(room, "room_id")
    nightly_rate_cents = field(room, "nightly_rate_cents")

    if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 do
      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_room(_room, _position), do: {:error, "invalid_rooms"}
  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp calculate_lodging(rooms, stay_length),
    do: Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * stay_length + &2))

  defp calculate_deposit(rooms, @advance_purchase, stay_length),
    do: calculate_lodging(rooms, stay_length)

  defp calculate_deposit(rooms, @flexible, stay_length),
    do: Enum.reduce(rooms, 0, &(room_deposit(&1, @flexible, stay_length) + &2))

  defp room_deposit(room, @advance_purchase, stay_length),
    do: room.nightly_rate_cents * stay_length

  defp room_deposit(room, @flexible, stay_length),
    do: round_percentage(room.nightly_rate_cents * stay_length, 20, 100)

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)
    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp outstanding(%{status: @active, deposit_due_cents: due, deposit_paid_cents: paid}),
    do: max(due - paid, 0)

  defp outstanding(_group), do: 0
end
