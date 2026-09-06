defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    AppliedHotelCredit,
    CreditLot,
    CreditLotEntitlement,
    Group,
    PartnerOperation,
    PaymentCashDisposition,
    PaymentCashSettlement,
    Room,
    RoomCashAllocation,
    RoomCreditAllocation
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_cutover ~D[2027-01-01]
  @funding_order_stride 1_000_000

  def submit_partner_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  def submit_partner_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where([group], group.group_id == ^group_id)
    |> preload_rooms()
    |> Repo.one()
  end

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      %PartnerOperation{result: result} -> result
    end
  end

  def get_payment_reconciliation(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      partner_operation ->
        if applied_cash_payment_operation?(partner_operation) do
          case Repo.get_by(PaymentCashDisposition, payment_operation_id: payment_operation_id) do
            nil ->
              {:error, :payment_not_reconcilable}

            disposition ->
              {:ok, serialize_payment_reconciliation(disposition)}
          end
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  def ledger_totals(on_date \\ Date.utc_today()) do
    payment_totals = payment_disposition_totals()
    legacy_totals = legacy_settled_cash_totals()

    %{
      cash_held_cents: active_held_cash_cents(),
      cash_refunded_cents: payment_totals.refunded_cents + legacy_totals.refunded_cents,
      cash_retained_cents: payment_totals.retained_cents + legacy_totals.retained_cents,
      cash_converted_to_credit_cents:
        payment_totals.converted_to_credit_cents + legacy_totals.converted_to_credit_cents,
      cash_reduced_cents: payment_totals.reduced_cents,
      cash_charged_back_cents: payment_totals.charged_back_cents,
      credit_liability_cents: credit_liability_cents(on_date),
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  def serialize_group(%Group{} = group) do
    policy_version = group_policy_version(group)
    rooms = rooms_for_group(group)
    room_totals = room_totals(rooms)
    active_totals = active_room_totals(group, rooms, room_totals)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      policy_version: policy_version,
      refundable_until: serialize_date(refundable_until(group, policy_version)),
      rooms: Enum.map(rooms, &serialize_room(&1, room_totals)),
      lodging_total_cents: active_totals.lodging_total_cents,
      deposit_due_cents: active_totals.deposit_due_cents,
      deposit_paid_cents: active_totals.deposit_paid_cents,
      cash_paid_cents: active_totals.cash_paid_cents,
      credit_paid_cents: active_totals.credit_paid_cents,
      outstanding_deposit_cents: active_totals.outstanding_deposit_cents
    }
  end

  def guest_credit(guest_id, on_date) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  def report_date_from_params(%{"on" => on_date}) when is_binary(on_date) do
    case Date.from_iso8601(on_date) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def report_date_from_params(%{"on" => _on_date}), do: {:error, :invalid_date}

  def report_date_from_params(_params), do: {:ok, Date.utc_today()}

  defp serialize_room(%Room{} = room, room_totals) do
    totals = Map.fetch!(room_totals, room.id)

    %{
      room_id: room.room_id,
      status: room.status,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_amount_cents: room.lodging_amount_cents,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents
    }
  end

  defp serialize_credit_lot(%CreditLot{} = credit_lot) do
    %{
      source_operation_id: credit_lot.source_operation_id,
      remaining_cents: credit_lot.remaining_cents,
      expires_on: Date.to_iso8601(credit_lot.expires_on)
    }
  end

  defp serialize_payment_reconciliation(%PaymentCashDisposition{} = disposition) do
    disposition = Repo.preload(disposition, :group)

    statement = %{
      payment_operation_id: disposition.payment_operation_id,
      original_group_id: disposition.group.group_id,
      recorded_cents: disposition.recorded_cents,
      held_cents: held_cash_for_payment(disposition.payment_operation_id),
      refunded_cents: disposition.refunded_cents,
      retained_cents: disposition.retained_cents,
      converted_to_credit_cents: disposition.converted_to_credit_cents,
      reduced_cents: disposition.reduced_cents,
      charged_back_cents: disposition.charged_back_cents
    }

    if disposition.transferred do
      Map.put(
        statement,
        :held_by_group,
        held_cash_by_group_for_payment(disposition.payment_operation_id)
      )
    else
      statement
    end
  end

  defp apply_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case reserve_operation(operation) do
          {:new, partner_operation} ->
            result =
              operation
              |> apply_domain_operation(partner_operation)
              |> normalize_json()

            partner_operation
            |> PartnerOperation.result_changeset(%{result: result})
            |> Repo.update!()

            result

          {:stored, result} ->
            result

          :conflict ->
            reject(operation_id, :operation_id_conflict)

          {:invalid, result} ->
            result
        end
      end)

    result
  end

  defp apply_operation(operation) do
    reject(operation_id_from(operation), :invalid_operation)
  end

  defp reserve_operation(operation) do
    payload = normalize_json(operation)

    attrs = %{
      operation_id: operation["operation_id"],
      operation_type: operation_type_from(operation),
      payload: payload
    }

    case Repo.insert(PartnerOperation.create_changeset(%PartnerOperation{}, attrs),
           mode: :savepoint
         ) do
      {:ok, partner_operation} ->
        {:new, partner_operation}

      {:error, changeset} ->
        if has_unique_operation_error?(changeset) do
          resolve_existing_operation(operation, payload)
        else
          {:invalid, reject(operation["operation_id"], :invalid_operation)}
        end
    end
  end

  defp resolve_existing_operation(operation, payload) do
    case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
      %PartnerOperation{payload: ^payload, result: result} when not is_nil(result) ->
        {:stored, result}

      %PartnerOperation{payload: ^payload, result: nil} ->
        raise "operation #{operation["operation_id"]} has no stored result"

      %PartnerOperation{} ->
        :conflict

      nil ->
        raise "operation #{operation["operation_id"]} conflicted without a stored record"
    end
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "open_group"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(open_group(operation))
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "record_cash_payment"} = operation,
         partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           :ok <- require_common_operation_date(operation),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_payment_within_outstanding(operation, group, amount_cents) do
        apply_cash_payment(
          operation,
          group,
          amount_cents,
          funding_order_for(partner_operation.id)
        )
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "apply_hotel_credit"} = operation,
         partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_payment_within_outstanding(operation, group, amount_cents),
           {:ok, credit_lots} <-
             fetch_covering_credit_lots(operation, group.guest_id, amount_cents, occurred_on) do
        apply_hotel_credit(
          operation,
          group,
          amount_cents,
          credit_lots,
          funding_order_for(partner_operation.id)
        )
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "transfer_deposit"} = operation,
         partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, source_group} <- fetch_group_by_field(operation, "source_group_id"),
           {:ok, destination_group} <- fetch_group_by_field(operation, "destination_group_id"),
           :ok <- check_expected_revision(operation, source_group),
           :ok <- check_destination_expected_revision(operation, destination_group),
           :ok <- ensure_valid_transfer_groups(operation, source_group, destination_group),
           :ok <- ensure_active_with_group_id(operation, source_group),
           :ok <- ensure_active_with_group_id(operation, destination_group),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_transfer_within_held_funding(operation, source_group, amount_cents),
           :ok <- ensure_transfer_within_outstanding(operation, destination_group, amount_cents) do
        transfer_deposit(
          operation,
          source_group,
          destination_group,
          amount_cents,
          funding_order_for(partner_operation.id)
        )
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "reschedule_group"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", :invalid_stay),
           :ok <- ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
        reschedule_group(operation, group, new_arrival_on)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "cancel_group"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, refund_method} <- fetch_refund_method(operation),
           :ok <- ensure_refund_method_available(operation, group, occurred_on, refund_method) do
        cancel_group(operation, group, occurred_on, refund_method)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "cancel_rooms"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, refund_method} <- fetch_refund_method(operation),
           :ok <- ensure_refund_method_available(operation, group, occurred_on, refund_method),
           {:ok, rooms} <- fetch_active_rooms_for_cancellation(operation, group) do
        cancel_rooms(operation, group, rooms, occurred_on, refund_method)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "reduce_cash_payment"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, payment_operation_id} <- fetch_string(operation, "payment_operation_id"),
           {:ok, disposition} <-
             fetch_cash_payment_disposition(
               operation,
               payment_operation_id,
               :payment_not_reducible
             ),
           group = Repo.preload(disposition, :group).group,
           :ok <- check_expected_revision(operation, group),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           held_cents = held_cash_for_payment(payment_operation_id),
           :ok <- ensure_payment_reducible(operation, held_cents),
           :ok <- ensure_reduction_within_held_cash(operation, amount_cents, held_cents) do
        reduce_cash_payment(operation, disposition, group, amount_cents)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "charge_back_payment"} = operation,
         _partner_operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, payment_operation_id} <- fetch_string(operation, "payment_operation_id"),
           {:ok, disposition} <-
             fetch_cash_payment_disposition(
               operation,
               payment_operation_id,
               :payment_not_chargeable
             ),
           group = Repo.preload(disposition, :group).group,
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_payment_chargeable(operation, disposition) do
        charge_back_payment(operation, disposition, group)
      end
    )
  end

  defp apply_domain_operation(operation, _partner_operation) do
    reject(operation_id_from(operation), :invalid_operation)
  end

  defp operation_result({:ok, result}), do: result
  defp operation_result({:error, result}), do: result

  defp open_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id"),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_operation_date(operation),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", :invalid_stay),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", :invalid_stay),
         :ok <- ensure_valid_stay(operation, arrival_on, departure_on),
         {:ok, rate_plan} <- fetch_rate_plan(operation),
         {:ok, rooms} <- build_rooms(operation, arrival_on, departure_on, rate_plan),
         :ok <- ensure_group_available(operation, group_id) do
      lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_amount_cents))
      deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
      policy_version = policy_version_for(rate_plan, booked_on)

      group_attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active,
        revision: 1,
        policy_version: policy_version,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      case Repo.insert(Group.changeset(%Group{}, group_attrs), mode: :savepoint) do
        {:ok, group} ->
          insert_rooms(group, rooms)

          {:ok,
           %{
             operation_id: operation["operation_id"],
             status: "applied",
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        {:error, changeset} ->
          if has_unique_group_error?(changeset) do
            {:error, reject(operation["operation_id"], :group_already_exists)}
          else
            {:error, reject(operation["operation_id"], :invalid_operation)}
          end
      end
    end
  end

  defp apply_cash_payment(operation, group, amount_cents, funding_order) do
    create_payment_disposition!(operation["operation_id"], group, amount_cents)
    allocate_cash_to_rooms!(group, amount_cents, operation["operation_id"], funding_order)

    updated_group = refresh_group_accounting!(group, %{revision: group.revision + 1})

    {:ok,
     %{
       operation_id: operation["operation_id"],
       status: "applied",
       group_id: updated_group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
       revision: updated_group.revision
     }}
  end

  defp apply_hotel_credit(operation, group, amount_cents, credit_lots, funding_order) do
    with :ok <- consume_credit_lots(operation, group, credit_lots, amount_cents, funding_order) do
      updated_group = refresh_group_accounting!(group, %{revision: group.revision + 1})

      {:ok,
       %{
         operation_id: operation["operation_id"],
         status: "applied",
         group_id: updated_group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
         revision: updated_group.revision
       }}
    end
  end

  defp transfer_deposit(operation, source_group, destination_group, amount_cents, funding_order) do
    chunks = draw_held_funding!(source_group, amount_cents)
    allocate_transferred_funding!(destination_group, chunks, funding_order)

    updated_source_group =
      refresh_group_accounting!(source_group, %{revision: source_group.revision + 1})

    updated_destination_group =
      refresh_group_accounting!(destination_group, %{revision: destination_group.revision + 1})

    {:ok,
     %{
       operation_id: operation["operation_id"],
       status: "applied",
       source_group_id: updated_source_group.group_id,
       destination_group_id: updated_destination_group.group_id,
       amount_cents: amount_cents,
       source_outstanding_deposit_cents: outstanding_deposit_cents(updated_source_group),
       destination_outstanding_deposit_cents:
         outstanding_deposit_cents(updated_destination_group),
       source_revision: updated_source_group.revision,
       destination_revision: updated_destination_group.revision
     }}
  end

  defp reschedule_group(operation, group, new_arrival_on) do
    stay_length_days = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, stay_length_days)

    group
    |> Group.changeset(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: group.revision + 1
    })
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        policy_version = group_policy_version(updated_group)

        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           policy_version: policy_version,
           refundable_until: serialize_date(refundable_until(updated_group, policy_version)),
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp cancel_group(operation, group, occurred_on, refund_method) do
    group
    |> active_rooms()
    |> settle_room_cancellation(operation, group, occurred_on, refund_method)
    |> case do
      {:ok, settlement, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: updated_group.revision
         }}
    end
  end

  defp cancel_rooms(operation, group, rooms, occurred_on, refund_method) do
    case settle_room_cancellation(rooms, operation, group, occurred_on, refund_method) do
      {:ok, settlement, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           cancelled_room_ids: Enum.map(rooms, & &1.room_id),
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: updated_group.revision
         }}
    end
  end

  defp reduce_cash_payment(operation, disposition, group, amount_cents) do
    changed_group_ids =
      remove_held_cash_allocations!(disposition.payment_operation_id, amount_cents)

    disposition
    |> PaymentCashDisposition.changeset(%{
      reduced_cents: disposition.reduced_cents + amount_cents
    })
    |> Repo.update!()

    updated_group =
      changed_group_ids
      |> refresh_changed_groups!(group)
      |> Map.fetch!(group.id)

    {:ok,
     %{
       operation_id: operation["operation_id"],
       status: "applied",
       payment_operation_id: disposition.payment_operation_id,
       group_id: updated_group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
       revision: updated_group.revision
     }}
  end

  defp charge_back_payment(operation, disposition, group) do
    settlement_records = payment_cash_settlements_for_payment(disposition.payment_operation_id)
    held_cents = held_cash_for_payment(disposition.payment_operation_id)

    changed_group_ids =
      remove_held_cash_allocations!(disposition.payment_operation_id, held_cents)

    revoke_credit_entitlements!(disposition.payment_operation_id)

    charged_back_cents =
      held_cents + disposition.refunded_cents + disposition.retained_cents +
        disposition.converted_to_credit_cents

    disposition
    |> PaymentCashDisposition.changeset(%{
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: disposition.charged_back_cents + charged_back_cents,
      charged_back: true
    })
    |> Repo.update!()

    delete_payment_cash_settlements!(settlement_records)

    updated_group =
      changed_group_ids
      |> MapSet.union(MapSet.new(Enum.map(settlement_records, & &1.group_pk_id)))
      |> refresh_changed_groups!(
        group,
        settlement_reversal_deltas_by_group(settlement_records)
      )
      |> Map.fetch!(group.id)

    {:ok,
     %{
       operation_id: operation["operation_id"],
       status: "applied",
       payment_operation_id: disposition.payment_operation_id,
       group_id: updated_group.group_id,
       charged_back_cents: charged_back_cents,
       outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
       revision: updated_group.revision
     }}
  end

  defp settle_room_cancellation([], operation, _group, _occurred_on, _refund_method) do
    {:error, reject(operation["operation_id"], :invalid_rooms)}
  end

  defp settle_room_cancellation(rooms, operation, group, occurred_on, refund_method) do
    cash_allocations = cash_allocations_for_rooms(rooms)
    credit_allocations = credit_allocations_for_rooms(rooms)
    cash_cents = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    refundable? = refundable?(group, occurred_on)
    settlement = cancellation_settlement(cash_cents, refundable?, refund_method)

    Enum.each(credit_allocations, fn allocation ->
      settle_credit_allocation!(allocation, occurred_on, refundable?)
    end)

    Enum.each(cash_allocations, fn allocation ->
      settle_cash_allocation!(allocation, settlement.disposition)
    end)

    maybe_issue_credit_lot(
      operation,
      group,
      settlement.credit_issued_cents,
      occurred_on,
      cash_allocations
    )

    mark_rooms_cancelled!(rooms)

    group_status =
      if active_room_count(group) == 0 do
        @cancelled
      else
        @active
      end

    updated_group =
      refresh_group_accounting!(group, %{
        status: group_status,
        revision: group.revision + 1,
        refunded_cents: group.refunded_cents + settlement.refunded_cents,
        retained_cents: group.retained_cents + settlement.retained_cents,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents + settlement.cash_converted_to_credit_cents
      })

    {:ok, settlement, updated_group}
  end

  defp cancellation_settlement(cash_cents, true, @cash) do
    %{
      refundable?: true,
      disposition: :refunded_cents,
      refunded_cents: cash_cents,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp cancellation_settlement(cash_cents, false, @cash) do
    %{
      refundable?: false,
      disposition: :retained_cents,
      refunded_cents: 0,
      retained_cents: cash_cents,
      cash_converted_to_credit_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp cancellation_settlement(cash_cents, true, @hotel_credit) do
    %{
      refundable?: true,
      disposition: :converted_to_credit_cents,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: cash_cents,
      credit_issued_cents: credit_issued_cents(cash_cents)
    }
  end

  defp maybe_issue_credit_lot(_operation, _group, 0, _occurred_on, _cash_allocations),
    do: {:ok, nil}

  defp maybe_issue_credit_lot(
         operation,
         group,
         credit_issued_cents,
         occurred_on,
         cash_allocations
       ) do
    credit_lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        issued_on: occurred_on,
        original_cents: credit_issued_cents,
        remaining_cents: credit_issued_cents,
        unrecovered_clawback_cents: 0,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()

    create_credit_lot_entitlements!(credit_lot, cash_allocations)

    {:ok, credit_lot}
  end

  defp create_credit_lot_entitlements!(credit_lot, cash_allocations) do
    cash_allocations
    |> combine_cash_principals_by_payment()
    |> Enum.reduce(0, fn %{payment_operation_id: payment_operation_id, principal_cents: principal},
                         previous ->
      current = previous + principal
      entitlement_cents = credit_issued_cents(current) - credit_issued_cents(previous)

      %CreditLotEntitlement{}
      |> CreditLotEntitlement.changeset(%{
        hotel_credit_lot_id: credit_lot.id,
        payment_operation_id: payment_operation_id,
        principal_cents: principal,
        entitlement_cents: entitlement_cents
      })
      |> Repo.insert!()

      current
    end)
  end

  defp combine_cash_principals_by_payment(cash_allocations) do
    cash_allocations
    |> Enum.reduce([], fn allocation, entries ->
      payment_operation_id = allocation.source_operation_id

      case List.last(entries) do
        %{payment_operation_id: ^payment_operation_id} = entry ->
          List.replace_at(entries, -1, %{
            entry
            | principal_cents: entry.principal_cents + allocation.amount_cents
          })

        _other ->
          entries ++
            [
              %{
                payment_operation_id: payment_operation_id,
                principal_cents: allocation.amount_cents
              }
            ]
      end
    end)
  end

  defp consume_credit_lots(operation, group, credit_lots, amount_cents, funding_order) do
    remaining_amount =
      Enum.reduce_while(credit_lots, amount_cents, fn credit_lot, amount_left ->
        cond do
          amount_left == 0 ->
            {:halt, 0}

          credit_lot.remaining_cents == 0 ->
            {:cont, amount_left}

          true ->
            amount_to_apply = min(amount_left, credit_lot.remaining_cents)

            credit_lot
            |> CreditLot.changeset(%{
              remaining_cents: credit_lot.remaining_cents - amount_to_apply
            })
            |> Repo.update!()

            %AppliedHotelCredit{}
            |> AppliedHotelCredit.changeset(%{
              group_pk_id: group.id,
              hotel_credit_lot_id: credit_lot.id,
              amount_cents: amount_to_apply
            })
            |> Repo.insert!()

            allocate_credit_to_rooms!(
              group,
              amount_to_apply,
              credit_lot.id,
              operation["operation_id"],
              funding_order
            )

            {:cont, amount_left - amount_to_apply}
        end
      end)

    case remaining_amount do
      0 -> :ok
      _amount_left -> {:error, reject(operation["operation_id"], :insufficient_credit)}
    end
  end

  defp fetch_addressed_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id") do
      case get_group(group_id) do
        nil -> {:error, reject(operation["operation_id"], :group_not_found)}
        group -> {:ok, group}
      end
    end
  end

  defp fetch_group_by_field(operation, field) do
    with {:ok, group_id} <- fetch_string(operation, field) do
      case get_group(group_id) do
        nil -> {:error, reject_with_group(operation["operation_id"], :group_not_found, group_id)}
        group -> {:ok, group}
      end
    end
  end

  defp check_expected_revision(operation, %Group{} = group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: operation["operation_id"],
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp check_destination_expected_revision(operation, %Group{} = group) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: operation["operation_id"],
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_valid_transfer_groups(operation, source_group, destination_group) do
    if source_group.id != destination_group.id and
         source_group.guest_id == destination_group.guest_id do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_transfer)}
    end
  end

  defp ensure_active_with_group_id(_operation, %Group{status: @active}), do: :ok

  defp ensure_active_with_group_id(operation, %Group{} = group) do
    {:error, reject_with_group(operation["operation_id"], :group_not_active, group.group_id)}
  end

  defp require_common_operation_date(operation) do
    case fetch_operation_date(operation) do
      {:ok, _date} -> :ok
      {:error, result} -> {:error, result}
    end
  end

  defp fetch_operation_date(operation) do
    fetch_date(operation, "occurred_on", :invalid_operation)
  end

  defp fetch_date(operation, key, code) do
    case fetch_string(operation, key) do
      {:ok, value} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, reject(operation["operation_id"], code)}
        end

      {:error, result} ->
        {:error, result}
    end
  end

  defp fetch_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp fetch_rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      _ -> {:error, reject(operation["operation_id"], :invalid_rate_plan)}
    end
  end

  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method", @cash) do
      @cash -> {:ok, @cash}
      @hotel_credit -> {:ok, @hotel_credit}
      _refund_method -> {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp fetch_room_ids(operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) and Enum.uniq(room_ids) == room_ids do
          {:ok, room_ids}
        else
          {:error, reject(operation["operation_id"], :invalid_rooms)}
        end

      _other ->
        {:error, reject(operation["operation_id"], :invalid_rooms)}
    end
  end

  defp fetch_active_rooms_for_cancellation(operation, group) do
    with {:ok, room_ids} <- fetch_room_ids(operation) do
      active_rooms = active_rooms(group)
      active_rooms_by_id = Map.new(active_rooms, &{&1.room_id, &1})

      if Enum.all?(room_ids, &Map.has_key?(active_rooms_by_id, &1)) do
        selected =
          active_rooms
          |> Enum.filter(&(&1.room_id in room_ids))
          |> Enum.sort_by(& &1.position)

        {:ok, selected}
      else
        {:error, reject(operation["operation_id"], :invalid_rooms)}
      end
    end
  end

  defp build_rooms(operation, arrival_on, departure_on, rate_plan) do
    with {:ok, rooms} when is_list(rooms) and rooms != [] <- Map.fetch(operation, "rooms"),
         true <- unique_room_ids?(rooms),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, built_rooms} ->
        case build_room(room, position, nights, rate_plan) do
          {:ok, built_room} -> {:cont, {:ok, [built_room | built_rooms]}}
          :error -> {:halt, {:error, reject(operation["operation_id"], :invalid_rooms)}}
        end
      end)
      |> case do
        {:ok, built_rooms} -> {:ok, Enum.reverse(built_rooms)}
        error -> error
      end
    else
      _ -> {:error, reject(operation["operation_id"], :invalid_rooms)}
    end
  end

  defp build_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    lodging_amount_cents = nightly_rate_cents * nights

    {:ok,
     %{
       room_id: room_id,
       position: position,
       status: @active,
       nightly_rate_cents: nightly_rate_cents,
       lodging_amount_cents: lodging_amount_cents,
       deposit_due_cents: room_deposit_due_cents(lodging_amount_cents, rate_plan)
     }}
  end

  defp build_room(_room, _position, _nights, _rate_plan), do: :error

  defp unique_room_ids?(rooms) do
    room_ids =
      Enum.map(rooms, fn
        %{"room_id" => room_id} when is_binary(room_id) and room_id != "" -> room_id
        _room -> nil
      end)

    Enum.all?(room_ids, &is_binary/1) and Enum.uniq(room_ids) == room_ids
  end

  defp room_deposit_due_cents(lodging_amount_cents, @flexible) do
    round_half_up(lodging_amount_cents, 20, 100)
  end

  defp room_deposit_due_cents(lodging_amount_cents, @advance_purchase), do: lodging_amount_cents

  defp round_half_up(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp funding_order_for(partner_operation_id) do
    partner_operation_id * @funding_order_stride
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.exists?(from(group in Group, where: group.group_id == ^group_id)) do
      true -> {:error, reject(operation["operation_id"], :group_already_exists)}
      false -> :ok
    end
  end

  defp ensure_valid_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) > 0 do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group),
    do: {:error, reject(operation["operation_id"], :group_not_active)}

  defp fetch_payment_amount_value(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} ->
        {:ok, amount_cents}

      :error ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp ensure_usable_payment_amount(_operation, amount_cents)
       when is_integer(amount_cents) and amount_cents > 0 do
    :ok
  end

  defp ensure_usable_payment_amount(operation, _amount_cents) do
    {:error, reject(operation["operation_id"], :invalid_amount)}
  end

  defp ensure_payment_within_outstanding(operation, group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      {:error, reject(operation["operation_id"], :payment_exceeds_outstanding)}
    end
  end

  defp ensure_transfer_within_held_funding(operation, source_group, amount_cents) do
    if amount_cents <= held_funding_cents(source_group) do
      :ok
    else
      {:error, reject(operation["operation_id"], :transfer_exceeds_held_funding)}
    end
  end

  defp ensure_transfer_within_outstanding(operation, destination_group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(destination_group) do
      :ok
    else
      {:error, reject(operation["operation_id"], :transfer_exceeds_outstanding)}
    end
  end

  defp ensure_payment_reducible(operation, held_cents) do
    if held_cents > 0 do
      :ok
    else
      {:error, reject(operation["operation_id"], :payment_not_reducible)}
    end
  end

  defp ensure_reduction_within_held_cash(operation, amount_cents, held_cents) do
    if amount_cents <= held_cents do
      :ok
    else
      {:error, reject(operation["operation_id"], :reduction_exceeds_held_cash)}
    end
  end

  defp ensure_payment_chargeable(operation, %PaymentCashDisposition{} = disposition) do
    chargeable_cents =
      disposition.recorded_cents - disposition.reduced_cents - disposition.charged_back_cents

    if not disposition.charged_back and chargeable_cents > 0 do
      :ok
    else
      {:error, reject(operation["operation_id"], :payment_not_chargeable)}
    end
  end

  defp fetch_covering_credit_lots(operation, guest_id, amount_cents, occurred_on) do
    credit_lots = available_credit_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(credit_lots, & &1.remaining_cents)) >= amount_cents do
      {:ok, credit_lots}
    else
      {:error, reject(operation["operation_id"], :insufficient_credit)}
    end
  end

  defp fetch_cash_payment_disposition(operation, payment_operation_id, unreconcilable_code) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, reject(operation["operation_id"], :operation_not_found)}

      partner_operation ->
        if applied_cash_payment_operation?(partner_operation) do
          case Repo.get_by(PaymentCashDisposition, payment_operation_id: payment_operation_id) do
            nil -> {:error, reject(operation["operation_id"], unreconcilable_code)}
            disposition -> {:ok, disposition}
          end
        else
          {:error, reject(operation["operation_id"], unreconcilable_code)}
        end
    end
  end

  defp applied_cash_payment_operation?(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: %{"status" => "applied"}
       }) do
    true
  end

  defp applied_cash_payment_operation?(_partner_operation), do: false

  defp ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp ensure_refund_method_available(operation, group, occurred_on, @hotel_credit) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, reject(operation["operation_id"], :refund_method_not_available)}
    end
  end

  defp ensure_refund_method_available(_operation, _group, _occurred_on, @cash), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(group), do: refundable_until(group, group_policy_version(group))

  defp refundable_until(group, @flex_14), do: Date.add(group.arrival_on, -14)
  defp refundable_until(group, @flex_30), do: Date.add(group.arrival_on, -30)
  defp refundable_until(_group, @advance_nonrefundable), do: nil

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in [@flex_14, @flex_30, @advance_nonrefundable] do
    policy_version
  end

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp credit_issued_cents(0), do: 0
  defp credit_issued_cents(cash_cents), do: cash_cents + round_half_up(cash_cents, 10, 100)

  defp outstanding_deposit_cents(%Group{} = group) do
    group
    |> active_room_totals()
    |> Map.fetch!(:outstanding_deposit_cents)
  end

  defp insert_rooms(group, rooms) do
    Enum.each(rooms, fn room_attrs ->
      attrs = Map.put(room_attrs, :group_pk_id, group.id)

      %Room{}
      |> Room.changeset(attrs)
      |> Repo.insert!()
    end)
  end

  defp create_payment_disposition!(payment_operation_id, group, amount_cents) do
    %PaymentCashDisposition{}
    |> PaymentCashDisposition.changeset(%{
      group_pk_id: group.id,
      payment_operation_id: payment_operation_id,
      recorded_cents: amount_cents,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0,
      charged_back: false,
      transferred: false
    })
    |> Repo.insert!()
  end

  defp allocate_cash_to_rooms!(group, amount_cents, source_operation_id, funding_order) do
    allocation_plan(group, amount_cents)
    |> Enum.each(fn {room, amount_to_allocate} ->
      %RoomCashAllocation{}
      |> RoomCashAllocation.changeset(%{
        group_pk_id: group.id,
        group_room_id: room.id,
        source_operation_id: source_operation_id,
        amount_cents: amount_to_allocate,
        funding_order: funding_order
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_credit_to_rooms!(
         group,
         amount_cents,
         hotel_credit_lot_id,
         operation_id,
         funding_order
       ) do
    allocation_plan(group, amount_cents)
    |> Enum.each(fn {room, amount_to_allocate} ->
      %RoomCreditAllocation{}
      |> RoomCreditAllocation.changeset(%{
        group_pk_id: group.id,
        group_room_id: room.id,
        hotel_credit_lot_id: hotel_credit_lot_id,
        application_operation_id: operation_id,
        amount_cents: amount_to_allocate,
        funding_order: funding_order
      })
      |> Repo.insert!()
    end)
  end

  defp allocation_plan(group, amount_cents) do
    rooms = active_rooms(group)
    room_totals = room_totals(rooms)

    {plan, amount_left} =
      Enum.reduce(rooms, {[], amount_cents}, fn room, {plan, amount_left} ->
        totals = Map.fetch!(room_totals, room.id)
        paid_cents = totals.cash_paid_cents + totals.credit_paid_cents
        available_cents = max(room.deposit_due_cents - paid_cents, 0)
        amount_to_allocate = min(amount_left, available_cents)

        plan =
          if amount_to_allocate > 0 do
            plan ++ [{room, amount_to_allocate}]
          else
            plan
          end

        {plan, amount_left - amount_to_allocate}
      end)

    if amount_left == 0 do
      plan
    else
      raise "could not allocate #{amount_left} cents for group #{group.group_id}"
    end
  end

  defp draw_held_funding!(group, amount_cents) do
    {amount_left, chunks} =
      group
      |> held_funding_allocations_for_group()
      |> Enum.reduce_while({amount_cents, []}, fn entry, {amount_left, chunks} ->
        amount_to_draw = min(amount_left, entry.amount_cents)
        remove_funding_from_source!(entry, amount_to_draw)

        chunk =
          entry
          |> Map.take([
            :kind,
            :source_operation_id,
            :hotel_credit_lot_id,
            :application_operation_id
          ])
          |> Map.put(:amount_cents, amount_to_draw)

        case amount_left - amount_to_draw do
          0 -> {:halt, {0, chunks ++ [chunk]}}
          remaining -> {:cont, {remaining, chunks ++ [chunk]}}
        end
      end)

    if amount_left == 0 do
      chunks
    else
      raise "could not draw #{amount_left} cents from group #{group.group_id}"
    end
  end

  defp remove_funding_from_source!(%{kind: :cash, allocation: allocation}, amount_cents) do
    reduce_or_delete_allocation!(RoomCashAllocation, allocation, amount_cents)
    mark_payment_transferred!(allocation.source_operation_id)
  end

  defp remove_funding_from_source!(%{kind: :credit, allocation: allocation}, amount_cents) do
    reduce_or_delete_allocation!(RoomCreditAllocation, allocation, amount_cents)
    remove_applied_credit!(allocation.group_pk_id, allocation.hotel_credit_lot_id, amount_cents)
  end

  defp allocate_transferred_funding!(destination_group, chunks, funding_order) do
    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, index} ->
      allocate_transferred_chunk!(destination_group, chunk, funding_order + index)
    end)
  end

  defp allocate_transferred_chunk!(destination_group, %{kind: :cash} = chunk, funding_order) do
    allocation_plan(destination_group, chunk.amount_cents)
    |> Enum.each(fn {room, amount_to_allocate} ->
      %RoomCashAllocation{}
      |> RoomCashAllocation.changeset(%{
        group_pk_id: destination_group.id,
        group_room_id: room.id,
        source_operation_id: chunk.source_operation_id,
        amount_cents: amount_to_allocate,
        funding_order: funding_order
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_transferred_chunk!(destination_group, %{kind: :credit} = chunk, funding_order) do
    add_applied_credit!(
      destination_group.id,
      chunk.hotel_credit_lot_id,
      chunk.amount_cents
    )

    allocation_plan(destination_group, chunk.amount_cents)
    |> Enum.each(fn {room, amount_to_allocate} ->
      %RoomCreditAllocation{}
      |> RoomCreditAllocation.changeset(%{
        group_pk_id: destination_group.id,
        group_room_id: room.id,
        hotel_credit_lot_id: chunk.hotel_credit_lot_id,
        application_operation_id: chunk.application_operation_id,
        amount_cents: amount_to_allocate,
        funding_order: funding_order
      })
      |> Repo.insert!()
    end)
  end

  defp add_applied_credit!(group_pk_id, hotel_credit_lot_id, amount_cents) do
    %AppliedHotelCredit{}
    |> AppliedHotelCredit.changeset(%{
      group_pk_id: group_pk_id,
      hotel_credit_lot_id: hotel_credit_lot_id,
      amount_cents: amount_cents
    })
    |> Repo.insert!()
  end

  defp reduce_or_delete_allocation!(_schema, allocation, amount_cents)
       when amount_cents == allocation.amount_cents do
    Repo.delete!(allocation)
  end

  defp reduce_or_delete_allocation!(schema, allocation, amount_cents) do
    allocation
    |> schema.changeset(%{amount_cents: allocation.amount_cents - amount_cents})
    |> Repo.update!()
  end

  defp mark_payment_transferred!(nil), do: :ok

  defp mark_payment_transferred!(payment_operation_id) do
    case Repo.get_by(PaymentCashDisposition, payment_operation_id: payment_operation_id) do
      nil ->
        :ok

      %PaymentCashDisposition{transferred: true} ->
        :ok

      disposition ->
        disposition
        |> PaymentCashDisposition.changeset(%{transferred: true})
        |> Repo.update!()
    end
  end

  defp settle_cash_allocation!(%RoomCashAllocation{} = allocation, disposition_field) do
    if allocation.source_operation_id do
      disposition =
        Repo.get_by!(
          PaymentCashDisposition,
          payment_operation_id: allocation.source_operation_id
        )

      disposition
      |> PaymentCashDisposition.changeset(%{
        disposition_field => Map.fetch!(disposition, disposition_field) + allocation.amount_cents
      })
      |> Repo.update!()

      increment_payment_cash_settlement!(
        allocation.source_operation_id,
        allocation.group_pk_id,
        disposition_field,
        allocation.amount_cents
      )
    end

    Repo.delete!(allocation)
  end

  defp increment_payment_cash_settlement!(
         payment_operation_id,
         group_pk_id,
         disposition_field,
         amount_cents
       ) do
    settlement =
      Repo.get_by(PaymentCashSettlement,
        payment_operation_id: payment_operation_id,
        group_pk_id: group_pk_id
      ) ||
        %PaymentCashSettlement{
          payment_operation_id: payment_operation_id,
          group_pk_id: group_pk_id,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0
        }

    settlement
    |> PaymentCashSettlement.changeset(%{
      disposition_field => Map.fetch!(settlement, disposition_field) + amount_cents
    })
    |> Repo.insert_or_update!()
  end

  defp payment_cash_settlements_for_payment(payment_operation_id) do
    PaymentCashSettlement
    |> where([settlement], settlement.payment_operation_id == ^payment_operation_id)
    |> Repo.all()
  end

  defp delete_payment_cash_settlements!(settlement_records) do
    Enum.each(settlement_records, &Repo.delete!/1)
  end

  defp settlement_reversal_deltas_by_group(settlement_records) do
    Enum.reduce(settlement_records, %{}, fn settlement, deltas_by_group ->
      Map.update(
        deltas_by_group,
        settlement.group_pk_id,
        %{
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          converted_to_credit_cents: settlement.converted_to_credit_cents
        },
        fn deltas ->
          %{
            refunded_cents: deltas.refunded_cents + settlement.refunded_cents,
            retained_cents: deltas.retained_cents + settlement.retained_cents,
            converted_to_credit_cents:
              deltas.converted_to_credit_cents + settlement.converted_to_credit_cents
          }
        end
      )
    end)
  end

  defp settle_credit_allocation!(%RoomCreditAllocation{} = allocation, occurred_on, true) do
    credit_lot = Repo.get!(CreditLot, allocation.hotel_credit_lot_id)
    amount_to_restore = allocation.amount_cents
    amount_absorbed = min(credit_lot.unrecovered_clawback_cents, amount_to_restore)
    amount_after_shortfall = amount_to_restore - amount_absorbed

    remaining_cents =
      if Date.compare(credit_lot.expires_on, occurred_on) == :lt do
        credit_lot.remaining_cents
      else
        credit_lot.remaining_cents + amount_after_shortfall
      end

    credit_lot
    |> CreditLot.changeset(%{
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: credit_lot.unrecovered_clawback_cents - amount_absorbed
    })
    |> Repo.update!()

    remove_applied_credit!(
      allocation.group_pk_id,
      allocation.hotel_credit_lot_id,
      allocation.amount_cents
    )

    Repo.delete!(allocation)
  end

  defp settle_credit_allocation!(%RoomCreditAllocation{} = allocation, _occurred_on, false) do
    remove_applied_credit!(
      allocation.group_pk_id,
      allocation.hotel_credit_lot_id,
      allocation.amount_cents
    )

    Repo.delete!(allocation)
  end

  defp remove_applied_credit!(group_pk_id, hotel_credit_lot_id, amount_cents) do
    AppliedHotelCredit
    |> where(
      [applied_credit],
      applied_credit.group_pk_id == ^group_pk_id and
        applied_credit.hotel_credit_lot_id == ^hotel_credit_lot_id
    )
    |> order_by([applied_credit], asc: applied_credit.inserted_at, asc: applied_credit.id)
    |> Repo.all()
    |> Enum.reduce_while(amount_cents, fn applied_credit, amount_left ->
      amount_to_remove = min(amount_left, applied_credit.amount_cents)

      if amount_to_remove == applied_credit.amount_cents do
        Repo.delete!(applied_credit)
      else
        applied_credit
        |> AppliedHotelCredit.changeset(%{
          amount_cents: applied_credit.amount_cents - amount_to_remove
        })
        |> Repo.update!()
      end

      case amount_left - amount_to_remove do
        0 -> {:halt, 0}
        remaining -> {:cont, remaining}
      end
    end)
  end

  defp remove_held_cash_allocations!(_payment_operation_id, 0), do: MapSet.new()

  defp remove_held_cash_allocations!(payment_operation_id, amount_cents) do
    payment_operation_id
    |> held_cash_allocations_for_payment()
    |> Enum.reduce_while({amount_cents, MapSet.new()}, fn allocation, {amount_left, group_ids} ->
      amount_to_remove = min(amount_left, allocation.amount_cents)
      group_ids = MapSet.put(group_ids, allocation.group_pk_id)

      reduce_or_delete_allocation!(RoomCashAllocation, allocation, amount_to_remove)

      case amount_left - amount_to_remove do
        0 -> {:halt, {0, group_ids}}
        remaining -> {:cont, {remaining, group_ids}}
      end
    end)
    |> case do
      {0, group_ids} -> group_ids
      {remaining, _group_ids} -> raise "could not remove #{remaining} cents from payment"
    end
  end

  defp revoke_credit_entitlements!(payment_operation_id) do
    CreditLotEntitlement
    |> where([entitlement], entitlement.payment_operation_id == ^payment_operation_id)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      credit_lot = Repo.get!(CreditLot, entitlement.hotel_credit_lot_id)
      amount_from_remaining = min(credit_lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered_cents = entitlement.entitlement_cents - amount_from_remaining

      credit_lot
      |> CreditLot.changeset(%{
        remaining_cents: credit_lot.remaining_cents - amount_from_remaining,
        unrecovered_clawback_cents: credit_lot.unrecovered_clawback_cents + unrecovered_cents
      })
      |> Repo.update!()
    end)
  end

  defp mark_rooms_cancelled!(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Room.changeset(%{status: @cancelled})
      |> Repo.update!()
    end)
  end

  defp refresh_group_accounting!(group, attrs) do
    effective_group = %{group | status: Map.get(attrs, :status, group.status)}
    totals = active_room_totals_from_db(effective_group)

    group
    |> Group.changeset(
      Map.merge(
        %{
          lodging_total_cents: totals.lodging_total_cents,
          deposit_due_cents: totals.deposit_due_cents,
          deposit_paid_cents: totals.deposit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp refresh_changed_groups!(changed_group_ids, addressed_group, settlement_deltas \\ %{}) do
    changed_group_ids
    |> MapSet.put(addressed_group.id)
    |> Enum.map(fn group_pk_id ->
      group = Repo.get!(Group, group_pk_id)
      deltas = Map.get(settlement_deltas, group_pk_id, empty_settlement_delta())

      attrs =
        %{
          revision: group.revision + 1,
          refunded_cents: max(group.refunded_cents - deltas.refunded_cents, 0),
          retained_cents: max(group.retained_cents - deltas.retained_cents, 0),
          cash_converted_to_credit_cents:
            max(group.cash_converted_to_credit_cents - deltas.converted_to_credit_cents, 0)
        }

      updated_group = refresh_group_accounting!(group, attrs)
      {updated_group.id, updated_group}
    end)
    |> Map.new()
  end

  defp empty_settlement_delta do
    %{refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0}
  end

  defp active_room_totals(%Group{} = group) do
    rooms = rooms_for_group(group)
    active_room_totals(group, rooms, room_totals(rooms))
  end

  defp active_room_totals_from_db(%Group{} = group) do
    rooms = group |> all_rooms() |> Repo.all()
    active_room_totals(group, rooms, room_totals(rooms))
  end

  defp active_room_totals(group, rooms, room_totals) do
    active_rooms =
      if group.status == @active do
        Enum.filter(rooms, &(&1.status == @active))
      else
        []
      end

    Enum.reduce(
      active_rooms,
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn room, totals ->
        room_payment_totals = Map.fetch!(room_totals, room.id)

        %{
          lodging_total_cents: totals.lodging_total_cents + room.lodging_amount_cents,
          deposit_due_cents: totals.deposit_due_cents + room.deposit_due_cents,
          cash_paid_cents: totals.cash_paid_cents + room_payment_totals.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents + room_payment_totals.credit_paid_cents
        }
      end
    )
    |> then(fn totals ->
      deposit_paid_cents = totals.cash_paid_cents + totals.credit_paid_cents

      Map.merge(totals, %{
        deposit_paid_cents: deposit_paid_cents,
        outstanding_deposit_cents: max(totals.deposit_due_cents - deposit_paid_cents, 0)
      })
    end)
  end

  defp room_totals(rooms) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_by_room_id = allocation_totals_by_room(RoomCashAllocation, room_ids)
    credit_by_room_id = allocation_totals_by_room(RoomCreditAllocation, room_ids)

    Map.new(rooms, fn room ->
      {room.id,
       %{
         cash_paid_cents: Map.get(cash_by_room_id, room.id, 0),
         credit_paid_cents: Map.get(credit_by_room_id, room.id, 0)
       }}
    end)
  end

  defp allocation_totals_by_room(_schema, []), do: %{}

  defp allocation_totals_by_room(schema, room_ids) do
    schema
    |> where([allocation], allocation.group_room_id in ^room_ids)
    |> group_by([allocation], allocation.group_room_id)
    |> select([allocation], {allocation.group_room_id, sum(allocation.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  defp rooms_for_group(%Group{} = group) do
    if Ecto.assoc_loaded?(group.rooms) do
      Enum.sort_by(group.rooms, & &1.position)
    else
      group |> all_rooms() |> Repo.all()
    end
  end

  defp all_rooms(%Group{} = group) do
    Room
    |> where([room], room.group_pk_id == ^group.id)
    |> order_by([room], asc: room.position)
  end

  defp active_rooms(%Group{} = group) do
    group
    |> all_rooms()
    |> where([room], room.status == ^@active)
    |> Repo.all()
  end

  defp active_room_count(%Group{} = group) do
    Room
    |> where([room], room.group_pk_id == ^group.id and room.status == ^@active)
    |> Repo.aggregate(:count)
  end

  defp cash_allocations_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    RoomCashAllocation
    |> where([allocation], allocation.group_room_id in ^room_ids)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> order_by([allocation, room],
      asc: allocation.funding_order,
      asc: room.position,
      asc: allocation.inserted_at,
      asc: allocation.id
    )
    |> Repo.all()
  end

  defp credit_allocations_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    RoomCreditAllocation
    |> where([allocation], allocation.group_room_id in ^room_ids)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> order_by([allocation, room],
      asc: allocation.funding_order,
      asc: room.position,
      asc: allocation.inserted_at,
      asc: allocation.id
    )
    |> Repo.all()
  end

  defp held_cash_allocations_for_payment(payment_operation_id) do
    RoomCashAllocation
    |> where([allocation], allocation.source_operation_id == ^payment_operation_id)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> order_by([allocation, room, _group],
      desc: allocation.funding_order,
      desc: room.position,
      desc: allocation.inserted_at,
      desc: allocation.id
    )
    |> Repo.all()
  end

  defp held_cash_by_group_for_payment(payment_operation_id) do
    RoomCashAllocation
    |> where([allocation], allocation.source_operation_id == ^payment_operation_id)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> group_by([_allocation, _room, group], group.group_id)
    |> order_by([_allocation, _room, group], asc: group.group_id)
    |> select([allocation, _room, group], %{
      group_id: group.group_id,
      amount_cents: sum(allocation.amount_cents)
    })
    |> Repo.all()
  end

  defp held_cash_for_payment(payment_operation_id) do
    RoomCashAllocation
    |> where([allocation], allocation.source_operation_id == ^payment_operation_id)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> select([allocation, _room, _group], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp held_funding_cents(%Group{} = group) do
    cash_cents =
      held_funding_sum(RoomCashAllocation, group.id)

    credit_cents =
      held_funding_sum(RoomCreditAllocation, group.id)

    cash_cents + credit_cents
  end

  defp held_funding_sum(schema, group_pk_id) do
    schema
    |> where([allocation], allocation.group_pk_id == ^group_pk_id)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> select([allocation, _room, _group], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp held_funding_allocations_for_group(%Group{} = group) do
    cash_allocations =
      RoomCashAllocation
      |> where([allocation], allocation.group_pk_id == ^group.id)
      |> join(:inner, [allocation], room in assoc(allocation, :room))
      |> where([_allocation, room], room.status == ^@active)
      |> preload([_allocation, room], room: room)
      |> Repo.all()
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          funding_order: allocation.funding_order,
          room_position: allocation.room.position,
          inserted_at: allocation.inserted_at,
          id: allocation.id,
          source_operation_id: allocation.source_operation_id
        }
      end)

    credit_allocations =
      RoomCreditAllocation
      |> where([allocation], allocation.group_pk_id == ^group.id)
      |> join(:inner, [allocation], room in assoc(allocation, :room))
      |> where([_allocation, room], room.status == ^@active)
      |> preload([_allocation, room], room: room)
      |> Repo.all()
      |> Enum.map(fn allocation ->
        %{
          kind: :credit,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          funding_order: allocation.funding_order,
          room_position: allocation.room.position,
          inserted_at: allocation.inserted_at,
          id: allocation.id,
          hotel_credit_lot_id: allocation.hotel_credit_lot_id,
          application_operation_id: allocation.application_operation_id
        }
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(&allocation_sort_key/1, :desc)
  end

  defp allocation_sort_key(entry) do
    {
      entry.funding_order || 0,
      entry.room_position || 0,
      allocation_kind_order(entry.kind),
      timestamp_sort_value(entry.inserted_at),
      entry.id
    }
  end

  defp allocation_kind_order(:cash), do: 0
  defp allocation_kind_order(:credit), do: 1

  defp timestamp_sort_value(nil), do: 0
  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp active_held_cash_cents do
    RoomCashAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> select([allocation, _room, _group], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_liability_cents(on_date) do
    available_credit_totals =
      CreditLot
      |> where(
        [credit_lot],
        credit_lot.remaining_cents > 0 and credit_lot.issued_on <= ^on_date and
          credit_lot.expires_on >= ^on_date
      )
      |> select([credit_lot], coalesce(sum(credit_lot.remaining_cents), 0))
      |> Repo.one()

    active_applied_credit_totals =
      RoomCreditAllocation
      |> join(:inner, [allocation], room in assoc(allocation, :room))
      |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
      |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
      |> select([allocation, _room, _group], coalesce(sum(allocation.amount_cents), 0))
      |> Repo.one()

    available_credit_totals + active_applied_credit_totals
  end

  defp credit_shortfall_cents do
    CreditLot
    |> where([credit_lot], credit_lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.map(fn credit_lot ->
      min(credit_lot.unrecovered_clawback_cents, active_applied_credit_for_lot(credit_lot.id))
    end)
    |> Enum.sum()
  end

  defp active_applied_credit_for_lot(credit_lot_id) do
    RoomCreditAllocation
    |> where([allocation], allocation.hotel_credit_lot_id == ^credit_lot_id)
    |> join(:inner, [allocation], room in assoc(allocation, :room))
    |> join(:inner, [allocation, _room], group in assoc(allocation, :group))
    |> where([_allocation, room, group], room.status == ^@active and group.status == ^@active)
    |> select([allocation, _room, _group], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp payment_disposition_totals do
    PaymentCashDisposition
    |> select([disposition], %{
      refunded_cents: coalesce(sum(disposition.refunded_cents), 0),
      retained_cents: coalesce(sum(disposition.retained_cents), 0),
      converted_to_credit_cents: coalesce(sum(disposition.converted_to_credit_cents), 0),
      reduced_cents: coalesce(sum(disposition.reduced_cents), 0),
      charged_back_cents: coalesce(sum(disposition.charged_back_cents), 0)
    })
    |> Repo.one()
  end

  defp legacy_settled_cash_totals do
    payment_totals_by_group =
      PaymentCashSettlement
      |> group_by([settlement], settlement.group_pk_id)
      |> select([settlement], {
        settlement.group_pk_id,
        %{
          refunded_cents: coalesce(sum(settlement.refunded_cents), 0),
          retained_cents: coalesce(sum(settlement.retained_cents), 0),
          converted_to_credit_cents: coalesce(sum(settlement.converted_to_credit_cents), 0)
        }
      })
      |> Repo.all()
      |> Map.new()

    Group
    |> select([group], %{
      id: group.id,
      refunded_cents: group.refunded_cents,
      retained_cents: group.retained_cents,
      converted_to_credit_cents: group.cash_converted_to_credit_cents
    })
    |> Repo.all()
    |> Enum.reduce(
      %{refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0},
      fn group, totals ->
        payment_totals =
          Map.get(payment_totals_by_group, group.id, %{
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0
          })

        %{
          refunded_cents:
            totals.refunded_cents + max(group.refunded_cents - payment_totals.refunded_cents, 0),
          retained_cents:
            totals.retained_cents + max(group.retained_cents - payment_totals.retained_cents, 0),
          converted_to_credit_cents:
            totals.converted_to_credit_cents +
              max(
                group.converted_to_credit_cents - payment_totals.converted_to_credit_cents,
                0
              )
        }
      end
    )
  end

  defp available_credit_lots(guest_id, on_date) do
    CreditLot
    |> where(
      [credit_lot],
      credit_lot.guest_id == ^guest_id and credit_lot.remaining_cents > 0 and
        credit_lot.issued_on <= ^on_date and credit_lot.expires_on >= ^on_date
    )
    |> order_by([credit_lot],
      asc: credit_lot.expires_on,
      asc: credit_lot.source_operation_id,
      asc: credit_lot.id
    )
    |> Repo.all()
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_iso8601(date)

  defp reject(operation_id, code) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: to_string(code)
    }
  end

  defp reject_with_group(operation_id, code, group_id) do
    operation_id
    |> reject(code)
    |> Map.put(:group_id, group_id)
  end

  defp operation_id_from(%{"operation_id" => operation_id}), do: operation_id
  defp operation_id_from(_operation), do: nil

  defp operation_type_from(%{"type" => operation_type}) when is_binary(operation_type) do
    operation_type
  end

  defp operation_type_from(_operation), do: nil

  defp normalize_json(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp preload_rooms(queryable) do
    from(group in queryable,
      preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp has_unique_group_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_message, options}} -> options[:constraint] == :unique
      _error -> false
    end)
  end

  defp has_unique_operation_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_message, options}} -> options[:constraint] == :unique
      _error -> false
    end)
  end
end
