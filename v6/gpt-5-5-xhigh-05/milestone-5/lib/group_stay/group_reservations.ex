defmodule GroupStay.GroupReservations do
  import Ecto.Query

  alias GroupStay.GroupReservations.CashAllocation
  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.GroupReservations.HotelCreditApplication
  alias GroupStay.GroupReservations.HotelCreditEntitlement
  alias GroupStay.GroupReservations.HotelCreditLot
  alias GroupStay.GroupReservations.PartnerOperation
  alias GroupStay.GroupReservations.Room
  alias GroupStay.Repo

  @active_status "active"
  @cancelled_status "cancelled"
  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"

  @cash_refund_method "cash"
  @hotel_credit_refund_method "hotel_credit"

  @held_disposition "held"
  @refunded_disposition "refunded"
  @retained_disposition "retained"
  @converted_disposition "converted"
  @reduced_disposition "reduced"
  @charged_back_disposition "charged_back"

  @held_credit_status "held"
  @restored_credit_status "restored"
  @consumed_credit_status "consumed"

  @flex_14_policy_version "flex-14"
  @flex_30_policy_version "flex-30"
  @advance_policy_version "advance-nonrefundable"
  @flex_30_cutover ~D[2027-01-01]

  def submit_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) do
    case Repo.get_by(GroupReservation, group_id: group_id) do
      nil ->
        nil

      group ->
        group
        |> Repo.preload(:rooms)
        |> ensure_room_accounting_backfilled!()
        |> Repo.preload(:rooms, force: true)
    end
  end

  def group_payload(nil), do: nil

  def group_payload(%GroupReservation{} = group) do
    group = Repo.preload(group, :rooms)
    policy_version = policy_version(group)
    room_totals = room_totals(group)
    active_rooms = active_rooms(group)
    lodging_total_cents = sum_field(active_rooms, :lodging_total_cents)
    deposit_due_cents = sum_field(active_rooms, :deposit_due_cents)
    cash_paid_cents = sum_field(Map.values(room_totals.cash), :amount_cents)
    credit_paid_cents = sum_field(Map.values(room_totals.credit), :amount_cents)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until: nullable_date(refundable_until(group, policy_version)),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            status: room.status,
            cash_paid_cents: room_paid_cents(room_totals.cash, room),
            credit_paid_cents: room_paid_cents(room_totals.credit, room)
          }
        end),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: deposit_due_cents - cash_paid_cents - credit_paid_cents
    }
  end

  def ledger_totals(on_date \\ Date.utc_today()) do
    ensure_all_room_accounting_backfilled!()

    active_cash_query =
      from allocation in CashAllocation,
        join: room in assoc(allocation, :group_room),
        join: group in assoc(allocation, :group_reservation),
        where: allocation.disposition == ^@held_disposition,
        where: room.status == ^@active_status,
        where: group.status == ^@active_status,
        select: coalesce(sum(allocation.amount_cents), 0)

    refunded_query =
      cash_disposition_total_query(@refunded_disposition)

    retained_query =
      cash_disposition_total_query(@retained_disposition)

    converted_query =
      cash_disposition_total_query(@converted_disposition)

    %{
      cash_held_cents: Repo.one(active_cash_query),
      cash_refunded_cents: Repo.one(refunded_query),
      cash_retained_cents: Repo.one(retained_query),
      cash_converted_to_credit_cents: Repo.one(converted_query),
      cash_reduced_cents: Repo.one(cash_disposition_total_query(@reduced_disposition)),
      cash_charged_back_cents: Repo.one(cash_disposition_total_query(@charged_back_disposition)),
      credit_liability_cents: credit_liability_cents(on_date),
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  def guest_credit_payload(guest_id, on_date \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: sum_field(lots, :remaining_cents),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def get_operation_result(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> stored_result(operation)
    end
  end

  def get_payment_payload(payment_operation_id) do
    case cash_payment_operation(payment_operation_id) do
      {:ok, payment} ->
        _group = get_group(payment_group_id(payment))
        {:ok, payment_statement(payment)}

      {:error, :operation_not_found} ->
        {:error, :operation_not_found}

      {:error, :not_cash_payment} ->
        {:error, :payment_not_reconcilable}
    end
  end

  defp process_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} ->
        {:ok, result} =
          Repo.transaction(fn ->
            process_idempotent_operation(operation, operation_id)
          end)

        result

      :invalid_operation ->
        rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp process_idempotent_operation(operation, operation_id) do
    payload_json = canonical_json(operation)

    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        remember_and_apply_operation(operation, operation_id, payload_json)

      partner_operation ->
        replay_or_reject_conflict(partner_operation, operation_id, payload_json)
    end
  end

  defp remember_and_apply_operation(operation, operation_id, payload_json) do
    attrs = %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json
    }

    case Repo.insert(PartnerOperation.create_changeset(%PartnerOperation{}, attrs)) do
      {:ok, partner_operation} ->
        result = apply_operation(operation)
        result_json = canonical_json(result)

        partner_operation
        |> PartnerOperation.result_changeset(%{result_json: result_json})
        |> Repo.update!()

        result

      {:error, changeset} ->
        if changeset_error?(changeset, :operation_id) do
          partner_operation = Repo.get_by!(PartnerOperation, operation_id: operation_id)
          replay_or_reject_conflict(partner_operation, operation_id, payload_json)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_or_reject_conflict(partner_operation, operation_id, payload_json) do
    if partner_operation.payload_json == payload_json do
      stored_result(partner_operation)
    else
      rejection(operation_id, "operation_id_conflict")
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: with_existing_group(operation, &record_cash_payment(operation, &1))

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: with_existing_group(operation, &apply_hotel_credit(operation, &1))

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: with_existing_group(operation, &reschedule_group(operation, &1))

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: with_existing_group(operation, &cancel_group(operation, &1))

  defp apply_operation(%{"type" => "cancel_rooms"} = operation),
    do: with_existing_group(operation, &cancel_rooms(operation, &1))

  defp apply_operation(%{"type" => "transfer_deposit"} = operation),
    do: with_transfer_groups(operation, &transfer_deposit(operation, &1, &2))

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation),
    do:
      with_target_payment_group(
        operation,
        "payment_not_reducible",
        &reduce_cash_payment(operation, &1, &2)
      )

  defp apply_operation(%{"type" => "charge_back_payment"} = operation),
    do:
      with_target_payment_group(
        operation,
        "payment_not_chargeable",
        &charge_back_payment(operation, &1, &2)
      )

  defp apply_operation(operation), do: rejection(operation_id(operation), "invalid_operation")

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         :ok <- ensure_group_id_available(group_id),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rooms} <- required_rooms(operation),
         {:ok, deposit_calculator} <- deposit_calculator(rate_plan) do
      night_count = Date.diff(departure_on, arrival_on)

      rooms_with_totals =
        Enum.map(rooms, fn room ->
          lodging_total = night_count * room.nightly_rate_cents
          Map.put(room, :lodging_total_cents, lodging_total)
        end)

      lodging_total_cents = sum_field(rooms_with_totals, :lodging_total_cents)
      deposit_due_cents = sum_deposits(rooms_with_totals, deposit_calculator)

      rooms_with_deposits =
        Enum.map(rooms_with_totals, fn room ->
          Map.put(room, :deposit_due_cents, deposit_calculator.(room.lodging_total_cents))
        end)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version_for(rate_plan, booked_on),
        status: @active_status,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1,
        rooms:
          Enum.map(rooms_with_deposits, fn room ->
            %{
              position: room.position,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              lodging_total_cents: room.lodging_total_cents,
              deposit_due_cents: room.deposit_due_cents,
              status: @active_status
            }
          end)
      }

      case Repo.insert(GroupReservation.create_changeset(%GroupReservation{}, attrs)) do
        {:ok, group} ->
          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset_error?(changeset, :group_id) do
            rejection(operation_id, "group_already_exists")
          else
            rejection(operation_id, "invalid_operation")
          end
      end
    else
      :group_already_exists -> rejection(operation_id(operation), "group_already_exists")
      :invalid_rate_plan -> rejection(operation_id(operation), "invalid_rate_plan")
      :invalid_rooms -> rejection(operation_id(operation), "invalid_rooms")
      :invalid_stay -> rejection(operation_id(operation), "invalid_stay")
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp record_cash_payment(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- payment_within_outstanding?(group, amount_cents) do
      allocate_cash_to_rooms(group, operation_id, amount_cents)
      updated_group = update_group_accounting!(group, %{revision: group.revision + 1})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :payment_exceeds_outstanding -> rejection(operation_id, "payment_exceeds_outstanding")
    end
  end

  defp apply_hotel_credit(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- payment_within_outstanding?(group, amount_cents),
         {:ok, lots} <- credit_lots_covering(group.guest_id, amount_cents, occurred_on) do
      consume_credit_lots(group, lots, operation_id, amount_cents)
      updated_group = update_group_accounting!(group, %{revision: group.revision + 1})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :insufficient_credit -> rejection(operation_id, "insufficient_credit")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
      :payment_exceeds_outstanding -> rejection(operation_id, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      {:ok, updated_group} =
        Repo.update(
          GroupReservation.update_changeset(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })
        )

      policy_version = policy_version(updated_group)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
        new_departure_on: Date.to_iso8601(updated_group.departure_on),
        policy_version: policy_version,
        refundable_until: nullable_date(refundable_until(updated_group, policy_version)),
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
    end
  end

  defp cancel_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method) do
      settlement =
        settle_rooms(group, active_rooms(group), operation_id, occurred_on, refund_method)

      updated_group =
        update_group_accounting!(group, %{
          status: @cancelled_status,
          revision: group.revision + 1
        })

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
      :refund_method_not_available -> rejection(operation_id, "refund_method_not_available")
    end
  end

  defp cancel_rooms(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, selected_rooms} <- selected_active_rooms(group, operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method) do
      settlement = settle_rooms(group, selected_rooms, operation_id, occurred_on, refund_method)
      next_status = if active_rooms_remaining?(group), do: @active_status, else: @cancelled_status

      updated_group =
        update_group_accounting!(group, %{
          status: next_status,
          revision: group.revision + 1
        })

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        cancelled_room_ids: Enum.map(selected_rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_rooms -> rejection(operation_id, "invalid_rooms")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
      :refund_method_not_available -> rejection(operation_id, "refund_method_not_available")
    end
  end

  defp transfer_deposit(
         operation,
         %GroupReservation{} = source_group,
         %GroupReservation{} = destination_group
       ) do
    operation_id = operation_id(operation)

    with :ok <- valid_transfer_groups?(source_group, destination_group),
         :ok <- active_transfer_group?(source_group),
         :ok <- active_transfer_group?(destination_group),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- transfer_within_held_funding?(source_group, amount_cents),
         :ok <- transfer_within_outstanding?(destination_group, amount_cents) do
      move_held_funding(source_group, destination_group, amount_cents)

      updated_source_group =
        update_group_accounting!(source_group, %{revision: source_group.revision + 1})

      updated_destination_group =
        update_group_accounting!(destination_group, %{revision: destination_group.revision + 1})

      %{
        operation_id: operation_id,
        status: "applied",
        source_group_id: updated_source_group.group_id,
        destination_group_id: updated_destination_group.group_id,
        amount_cents: amount_cents,
        source_outstanding_deposit_cents: outstanding_deposit_cents(updated_source_group),
        destination_outstanding_deposit_cents:
          outstanding_deposit_cents(updated_destination_group),
        source_revision: updated_source_group.revision,
        destination_revision: updated_destination_group.revision
      }
    else
      {:group_not_active, group} ->
        rejection(operation_id, "group_not_active", group.group_id)

      :invalid_amount ->
        rejection(operation_id, "invalid_amount")

      :invalid_operation ->
        rejection(operation_id, "invalid_operation")

      :invalid_transfer ->
        rejection(operation_id, "invalid_transfer")

      :transfer_exceeds_held_funding ->
        rejection(operation_id, "transfer_exceeds_held_funding")

      :transfer_exceeds_outstanding ->
        rejection(operation_id, "transfer_exceeds_outstanding")
    end
  end

  defp reduce_cash_payment(operation, %GroupReservation{} = group, %PartnerOperation{} = payment) do
    operation_id = operation_id(operation)
    payment_operation_id = payment.operation_id

    with {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         held_cents when held_cents > 0 <- held_cash_for_payment(payment_operation_id),
         :ok <- reduction_within_held_cash?(amount_cents, held_cents) do
      changed_group_ids = reduce_held_cash(payment_operation_id, amount_cents)
      updated_group = update_changed_groups_accounting!(group, changed_group_ids)

      %{
        operation_id: operation_id,
        status: "applied",
        payment_operation_id: payment_operation_id,
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
        revision: updated_group.revision
      }
    else
      0 -> rejection(operation_id, "payment_not_reducible")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :reduction_exceeds_held_cash -> rejection(operation_id, "reduction_exceeds_held_cash")
    end
  end

  defp charge_back_payment(operation, %GroupReservation{} = group, %PartnerOperation{} = payment) do
    operation_id = operation_id(operation)
    payment_operation_id = payment.operation_id
    statement = payment_statement(payment)

    cond do
      statement.reduced_cents == statement.recorded_cents ->
        rejection(operation_id, "payment_not_chargeable")

      statement.charged_back_cents > 0 ->
        rejection(operation_id, "payment_not_chargeable")

      true ->
        charged_back_cents = statement.recorded_cents - statement.reduced_cents

        revoke_converted_credit_entitlements(payment_operation_id)
        changed_group_ids = charge_back_cash_allocations(payment_operation_id)

        updated_group = update_changed_groups_accounting!(group, changed_group_ids)

        %{
          operation_id: operation_id,
          status: "applied",
          payment_operation_id: payment_operation_id,
          group_id: updated_group.group_id,
          charged_back_cents: charged_back_cents,
          outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
          revision: updated_group.revision
        }
    end
  end

  defp with_existing_group(operation, callback) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case get_group(group_id) do
        nil ->
          rejection(operation_id, "group_not_found")

        group ->
          case expected_revision(operation) do
            {:ok, nil} ->
              callback.(group)

            {:ok, expected_revision} when expected_revision == group.revision ->
              callback.(group)

            {:ok, expected_revision} ->
              %{
                operation_id: operation_id,
                status: "rejected",
                code: "stale_revision",
                group_id: group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              }

            :invalid_operation ->
              rejection(operation_id, "invalid_operation")
          end
      end
    else
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp with_transfer_groups(operation, callback) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, source_group_id} <- required_string(operation, "source_group_id"),
         {:ok, destination_group_id} <- required_string(operation, "destination_group_id") do
      case get_group(source_group_id) do
        nil ->
          rejection(operation_id, "group_not_found", source_group_id)

        source_group ->
          case get_group(destination_group_id) do
            nil ->
              rejection(operation_id, "group_not_found", destination_group_id)

            destination_group ->
              with :ok <- revision_matches?(operation, source_group, "expected_revision"),
                   :ok <-
                     revision_matches?(
                       operation,
                       destination_group,
                       "destination_expected_revision"
                     ) do
                callback.(source_group, destination_group)
              else
                {:stale_revision, group, expected_revision} ->
                  stale_revision_rejection(operation_id, group, expected_revision)

                :invalid_operation ->
                  rejection(operation_id, "invalid_operation")
              end
          end
      end
    else
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp with_target_payment_group(operation, invalid_payment_code, callback) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         {:ok, payment} <- cash_payment_operation(payment_operation_id) do
      group_id = payment_group_id(payment)

      case get_group(group_id) do
        nil ->
          rejection(operation_id, "group_not_found")

        group ->
          case expected_revision(operation) do
            {:ok, nil} ->
              callback.(group, payment)

            {:ok, expected_revision} when expected_revision == group.revision ->
              callback.(group, payment)

            {:ok, expected_revision} ->
              %{
                operation_id: operation_id,
                status: "rejected",
                code: "stale_revision",
                group_id: group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              }

            :invalid_operation ->
              rejection(operation_id, "invalid_operation")
          end
      end
    else
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
      {:error, :operation_not_found} -> rejection(operation_id(operation), "operation_not_found")
      {:error, :not_cash_payment} -> rejection(operation_id(operation), invalid_payment_code)
    end
  end

  defp ensure_group_id_available(group_id) do
    if Repo.exists?(from group in GroupReservation, where: group.group_id == ^group_id) do
      :group_already_exists
    else
      :ok
    end
  end

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :invalid_operation
    end
  end

  defp required_integer(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_amount
      :error -> :invalid_operation
    end
  end

  defp required_date(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :invalid_stay
        end

      {:ok, _value} ->
        :invalid_stay

      :error ->
        :invalid_operation
    end
  end

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp required_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) ->
        normalize_rooms(rooms)

      {:ok, _rooms} ->
        :invalid_rooms

      :error ->
        :invalid_operation
    end
  end

  defp normalize_rooms([]), do: :invalid_rooms

  defp normalize_rooms(rooms) do
    normalized =
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {room, position}, acc ->
        case normalize_room(room, position) do
          {:ok, normalized_room} -> {:cont, [normalized_room | acc]}
          :invalid_rooms -> {:halt, :invalid_rooms}
        end
      end)

    case normalized do
      :invalid_rooms ->
        :invalid_rooms

      normalized_rooms ->
        rooms_in_original_order = Enum.reverse(normalized_rooms)
        room_ids = Enum.map(rooms_in_original_order, & &1.room_id)

        if length(Enum.uniq(room_ids)) == length(room_ids) do
          {:ok, rooms_in_original_order}
        else
          :invalid_rooms
        end
    end
  end

  defp normalize_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    {:ok, %{position: position, room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
  end

  defp normalize_room(_room, _position), do: :invalid_rooms

  defp deposit_calculator(@flexible_rate_plan), do: {:ok, &flexible_deposit_cents/1}
  defp deposit_calculator(@advance_purchase_rate_plan), do: {:ok, & &1}
  defp deposit_calculator(_rate_plan), do: :invalid_rate_plan

  defp flexible_deposit_cents(lodging_total_cents) do
    rounded_percentage_cents(lodging_total_cents, 20)
  end

  defp credit_bonus_cents(cash_cents) do
    rounded_percentage_cents(cash_cents, 10)
  end

  defp rounded_percentage_cents(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp sum_deposits(rooms, deposit_calculator) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + deposit_calculator.(room.lodging_total_cents)
    end)
  end

  defp sum_field(records, field) do
    Enum.reduce(records, 0, fn record, total -> total + Map.fetch!(record, field) end)
  end

  defp ensure_all_room_accounting_backfilled! do
    GroupReservation
    |> Repo.all()
    |> Repo.preload(:rooms)
    |> Enum.each(&ensure_room_accounting_backfilled!/1)
  end

  defp ensure_room_accounting_backfilled!(%GroupReservation{} = group) do
    backfill_cash_allocations!(group)
    backfill_credit_applications!(group)
    group
  end

  defp backfill_cash_allocations!(%GroupReservation{} = group) do
    has_allocations? =
      Repo.exists?(
        from allocation in CashAllocation,
          where: allocation.group_reservation_id == ^group.id
      )

    if not has_allocations? and (group.deposit_paid_cents || 0) > 0 do
      durable_payments = durable_cash_payments_for_group(group.group_id)

      durable_cash_cents =
        Enum.reduce(durable_payments, 0, &(stored_result(&1).amount_cents + &2))

      legacy_cash_cents = max(group.deposit_paid_cents - durable_cash_cents, 0)

      if group.status == @active_status do
        if legacy_cash_cents > 0 do
          allocate_cash_to_rooms(group, nil, legacy_cash_cents)
        end

        durable_payments
        |> Enum.reduce(max(group.deposit_paid_cents - legacy_cash_cents, 0), fn payment,
                                                                                remaining_cents ->
          amount_cents = min(stored_result(payment).amount_cents, remaining_cents)

          if amount_cents > 0 do
            allocate_cash_to_rooms(group, payment.operation_id, amount_cents)
          end

          remaining_cents - amount_cents
        end)
      else
        group
        |> settled_cash_backfill_plan()
        |> Enum.reduce(next_allocation_order(), fn {disposition, amount_cents},
                                                   allocation_order ->
          insert_cash_allocation!(group, nil, nil, disposition, amount_cents, allocation_order)
          allocation_order + 1
        end)
      end
    end

    :ok
  end

  defp durable_cash_payments_for_group(group_id) do
    PartnerOperation
    |> where([operation], operation.operation_type == "record_cash_payment")
    |> order_by([operation], asc: operation.id)
    |> Repo.all()
    |> Enum.filter(fn operation ->
      case stored_result(operation) do
        %{status: "applied", group_id: ^group_id, amount_cents: amount_cents}
        when is_integer(amount_cents) ->
          true

        _result ->
          false
      end
    end)
  end

  defp settled_cash_backfill_plan(group) do
    [
      {@refunded_disposition, group.refunded_cents || 0},
      {@retained_disposition, group.retained_cents || 0},
      {@converted_disposition, group.cash_converted_to_credit_cents || 0}
    ]
    |> Enum.reject(fn {_disposition, amount_cents} -> amount_cents == 0 end)
  end

  defp backfill_credit_applications!(%GroupReservation{status: @active_status} = group) do
    HotelCreditApplication
    |> where([application], application.group_reservation_id == ^group.id)
    |> where([application], is_nil(application.group_room_id))
    |> where([application], application.status == ^@held_credit_status)
    |> order_by([application], asc: application.inserted_at, asc: application.id)
    |> Repo.all()
    |> Enum.each(&assign_existing_credit_application_to_rooms!(group, &1))

    :ok
  end

  defp backfill_credit_applications!(_group), do: :ok

  defp assign_existing_credit_application_to_rooms!(group, application) do
    next_order = max(application.allocation_order + 1, next_allocation_order())

    group
    |> active_room_capacities()
    |> Enum.reduce_while({application.amount_cents, true, next_order}, fn {room, capacity_cents},
                                                                          {remaining_cents,
                                                                           first?,
                                                                           allocation_order} ->
      amount_for_room = min(capacity_cents, remaining_cents)

      if first? do
        application
        |> HotelCreditApplication.changeset(%{
          group_room_id: room.id,
          amount_cents: amount_for_room,
          status: @held_credit_status,
          allocation_order: application.allocation_order
        })
        |> Repo.update!()
      else
        insert_credit_application!(
          group,
          room,
          application.hotel_credit_lot_id,
          application.application_operation_id,
          amount_for_room,
          allocation_order
        )
      end

      case remaining_cents - amount_for_room do
        0 -> {:halt, {0, false, allocation_order + 1}}
        next_remaining_cents -> {:cont, {next_remaining_cents, false, allocation_order + 1}}
      end
    end)

    :ok
  end

  defp active_rooms(%GroupReservation{} = group) do
    group
    |> Repo.preload(:rooms)
    |> Map.fetch!(:rooms)
    |> Enum.filter(&(&1.status == @active_status))
  end

  defp active_rooms_remaining?(%GroupReservation{} = group) do
    Repo.exists?(
      from room in Room,
        where: room.group_reservation_id == ^group.id,
        where: room.status == ^@active_status
    )
  end

  defp room_totals(%GroupReservation{} = group) do
    group = Repo.preload(group, :rooms)
    room_ids = Enum.map(group.rooms, & &1.id)

    %{
      cash: held_cash_totals_by_room(room_ids),
      credit: held_credit_totals_by_room(room_ids)
    }
  end

  defp held_cash_totals_by_room([]), do: %{}

  defp held_cash_totals_by_room(room_ids) do
    CashAllocation
    |> where([allocation], allocation.group_room_id in ^room_ids)
    |> where([allocation], allocation.disposition == ^@held_disposition)
    |> group_by([allocation], allocation.group_room_id)
    |> select([allocation], {allocation.group_room_id, coalesce(sum(allocation.amount_cents), 0)})
    |> Repo.all()
    |> Map.new(fn {room_id, amount_cents} -> {room_id, %{amount_cents: amount_cents}} end)
  end

  defp held_credit_totals_by_room([]), do: %{}

  defp held_credit_totals_by_room(room_ids) do
    HotelCreditApplication
    |> where([application], application.group_room_id in ^room_ids)
    |> where([application], application.status == ^@held_credit_status)
    |> group_by([application], application.group_room_id)
    |> select(
      [application],
      {application.group_room_id, coalesce(sum(application.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {room_id, amount_cents} -> {room_id, %{amount_cents: amount_cents}} end)
  end

  defp room_paid_cents(totals, %Room{} = room) do
    totals
    |> Map.get(room.id, %{amount_cents: 0})
    |> Map.fetch!(:amount_cents)
  end

  defp active_room_capacities(%GroupReservation{} = group) do
    totals = room_totals(group)

    group
    |> active_rooms()
    |> Enum.map(fn room ->
      paid_cents = room_paid_cents(totals.cash, room) + room_paid_cents(totals.credit, room)
      {room, max(room.deposit_due_cents - paid_cents, 0)}
    end)
    |> Enum.reject(fn {_room, capacity_cents} -> capacity_cents == 0 end)
  end

  defp allocate_cash_to_rooms(group, payment_operation_id, amount_cents) do
    next_order = next_allocation_order()

    group
    |> active_room_capacities()
    |> Enum.reduce_while({amount_cents, next_order}, fn {room, capacity_cents},
                                                        {remaining_cents, allocation_order} ->
      amount_for_room = min(capacity_cents, remaining_cents)

      insert_cash_allocation!(
        group,
        room,
        payment_operation_id,
        @held_disposition,
        amount_for_room,
        allocation_order
      )

      case remaining_cents - amount_for_room do
        0 -> {:halt, {0, allocation_order + 1}}
        next_remaining_cents -> {:cont, {next_remaining_cents, allocation_order + 1}}
      end
    end)

    :ok
  end

  defp next_allocation_order do
    max_cash_order =
      CashAllocation
      |> select([allocation], max(allocation.allocation_order))
      |> Repo.one()

    max_credit_order =
      HotelCreditApplication
      |> select([application], max(application.allocation_order))
      |> Repo.one()

    max(max_cash_order || -1, max_credit_order || -1) + 1
  end

  defp insert_cash_allocation!(
         group,
         room,
         payment_operation_id,
         disposition,
         amount_cents,
         allocation_order,
         opts \\ []
       )
       when amount_cents > 0 do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      group_reservation_id: group.id,
      group_room_id: room && room.id,
      payment_operation_id: payment_operation_id,
      disposition: disposition,
      amount_cents: amount_cents,
      allocation_order: allocation_order,
      transferred: Keyword.get(opts, :transferred, false)
    })
    |> Repo.insert!()
  end

  defp insert_credit_application!(
         group,
         room,
         hotel_credit_lot_id,
         application_operation_id,
         amount_cents,
         allocation_order
       )
       when amount_cents > 0 do
    %HotelCreditApplication{}
    |> HotelCreditApplication.changeset(%{
      group_reservation_id: group.id,
      group_room_id: room && room.id,
      hotel_credit_lot_id: hotel_credit_lot_id,
      application_operation_id: application_operation_id,
      amount_cents: amount_cents,
      status: @held_credit_status,
      allocation_order: allocation_order
    })
    |> Repo.insert!()
  end

  defp move_held_funding(source_group, destination_group, amount_cents) do
    source_group
    |> held_funding_allocations_reverse()
    |> draw_held_funding(amount_cents)
    |> place_drawn_funding(destination_group)

    :ok
  end

  defp held_funding_allocations_reverse(%GroupReservation{} = group) do
    room_ids = group |> active_rooms() |> Enum.map(& &1.id)

    cash_allocations =
      CashAllocation
      |> where([allocation], allocation.group_reservation_id == ^group.id)
      |> where([allocation], allocation.group_room_id in ^room_ids)
      |> where([allocation], allocation.disposition == ^@held_disposition)
      |> preload(:group_room)
      |> Repo.all()
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          record: allocation,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order,
          id: allocation.id
        }
      end)

    credit_applications =
      HotelCreditApplication
      |> where([application], application.group_reservation_id == ^group.id)
      |> where([application], application.group_room_id in ^room_ids)
      |> where([application], application.status == ^@held_credit_status)
      |> preload(:group_room)
      |> Repo.all()
      |> Enum.map(fn application ->
        %{
          kind: :credit,
          record: application,
          amount_cents: application.amount_cents,
          allocation_order: application.allocation_order,
          id: application.id
        }
      end)

    [cash_allocations, credit_applications]
    |> List.flatten()
    |> Enum.sort_by(fn allocation -> {allocation.allocation_order, allocation.id} end, :desc)
  end

  defp draw_held_funding(allocations, amount_cents) do
    {_remaining_cents, drawn_allocations} =
      Enum.reduce_while(allocations, {amount_cents, []}, fn allocation,
                                                            {remaining_cents, drawn} ->
        amount_drawn = min(allocation.amount_cents, remaining_cents)
        drawn_allocation = draw_from_source_allocation!(allocation, amount_drawn)
        next_remaining_cents = remaining_cents - amount_drawn
        next_drawn = [drawn_allocation | drawn]

        case next_remaining_cents do
          0 -> {:halt, {0, next_drawn}}
          _ -> {:cont, {next_remaining_cents, next_drawn}}
        end
      end)

    Enum.reverse(drawn_allocations)
  end

  defp draw_from_source_allocation!(allocation, amount_drawn)
       when amount_drawn == allocation.amount_cents do
    Map.merge(allocation, %{amount_cents: amount_drawn, source_record_available?: true})
  end

  defp draw_from_source_allocation!(%{kind: :cash, record: record} = allocation, amount_drawn) do
    record
    |> CashAllocation.changeset(%{amount_cents: record.amount_cents - amount_drawn})
    |> Repo.update!()

    Map.merge(allocation, %{amount_cents: amount_drawn, source_record_available?: false})
  end

  defp draw_from_source_allocation!(%{kind: :credit, record: record} = allocation, amount_drawn) do
    record
    |> HotelCreditApplication.changeset(%{amount_cents: record.amount_cents - amount_drawn})
    |> Repo.update!()

    Map.merge(allocation, %{amount_cents: amount_drawn, source_record_available?: false})
  end

  defp place_drawn_funding(drawn_allocations, destination_group) do
    capacities = active_room_capacities(destination_group)

    Enum.reduce(drawn_allocations, {capacities, next_allocation_order()}, fn allocation,
                                                                             {current_capacities,
                                                                              allocation_order} ->
      place_drawn_allocation(
        destination_group,
        allocation,
        current_capacities,
        allocation.amount_cents,
        allocation.source_record_available?,
        allocation_order
      )
    end)

    :ok
  end

  defp place_drawn_allocation(
         _destination_group,
         _allocation,
         capacities,
         0,
         _source_record_available?,
         allocation_order
       ) do
    {capacities, allocation_order}
  end

  defp place_drawn_allocation(
         destination_group,
         allocation,
         [{room, capacity_cents} | remaining_capacities],
         remaining_cents,
         source_record_available?,
         allocation_order
       ) do
    amount_for_room = min(capacity_cents, remaining_cents)

    {next_source_record_available?, next_allocation_order} =
      place_funding_chunk!(
        destination_group,
        room,
        allocation,
        amount_for_room,
        source_record_available?,
        allocation_order
      )

    next_remaining_cents = remaining_cents - amount_for_room

    next_capacities =
      case capacity_cents - amount_for_room do
        0 -> remaining_capacities
        remaining_capacity -> [{room, remaining_capacity} | remaining_capacities]
      end

    place_drawn_allocation(
      destination_group,
      allocation,
      next_capacities,
      next_remaining_cents,
      next_source_record_available?,
      next_allocation_order
    )
  end

  defp place_funding_chunk!(
         destination_group,
         room,
         %{kind: :cash, record: record},
         amount_cents,
         true,
         allocation_order
       ) do
    record
    |> CashAllocation.changeset(%{
      group_reservation_id: destination_group.id,
      group_room_id: room.id,
      amount_cents: amount_cents,
      allocation_order: allocation_order,
      transferred: true
    })
    |> Repo.update!()

    {false, allocation_order + 1}
  end

  defp place_funding_chunk!(
         destination_group,
         room,
         %{kind: :cash, record: record},
         amount_cents,
         false,
         allocation_order
       ) do
    insert_cash_allocation!(
      destination_group,
      room,
      record.payment_operation_id,
      @held_disposition,
      amount_cents,
      allocation_order,
      transferred: true
    )

    {false, allocation_order + 1}
  end

  defp place_funding_chunk!(
         destination_group,
         room,
         %{kind: :credit, record: record},
         amount_cents,
         true,
         allocation_order
       ) do
    record
    |> HotelCreditApplication.changeset(%{
      group_reservation_id: destination_group.id,
      group_room_id: room.id,
      amount_cents: amount_cents,
      status: @held_credit_status,
      allocation_order: allocation_order
    })
    |> Repo.update!()

    {false, allocation_order + 1}
  end

  defp place_funding_chunk!(
         destination_group,
         room,
         %{kind: :credit, record: record},
         amount_cents,
         false,
         allocation_order
       ) do
    insert_credit_application!(
      destination_group,
      room,
      record.hotel_credit_lot_id,
      record.application_operation_id,
      amount_cents,
      allocation_order
    )

    {false, allocation_order + 1}
  end

  defp held_cash_allocations_for_rooms(_group_id, []), do: []

  defp held_cash_allocations_for_rooms(group_id, room_ids) do
    CashAllocation
    |> where([allocation], allocation.group_reservation_id == ^group_id)
    |> where([allocation], allocation.group_room_id in ^room_ids)
    |> where([allocation], allocation.disposition == ^@held_disposition)
    |> order_by([allocation], asc: allocation.allocation_order, asc: allocation.id)
    |> Repo.all()
  end

  defp held_credit_applications_for_rooms([]), do: []

  defp held_credit_applications_for_rooms(room_ids) do
    HotelCreditApplication
    |> where([application], application.group_room_id in ^room_ids)
    |> where([application], application.status == ^@held_credit_status)
    |> preload(:hotel_credit_lot)
    |> Repo.all()
  end

  defp reclassify_cash_allocations(allocations, disposition) do
    Enum.each(allocations, fn allocation ->
      allocation
      |> CashAllocation.changeset(%{disposition: disposition})
      |> Repo.update!()
    end)

    :ok
  end

  defp cancel_room_records(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Room.changeset(%{status: @cancelled_status})
      |> Repo.update!()
    end)

    :ok
  end

  defp update_credit_application_status!(application, status) do
    application
    |> HotelCreditApplication.changeset(%{status: status})
    |> Repo.update!()
  end

  defp update_group_accounting!(%GroupReservation{} = group, attrs) do
    group =
      group
      |> Repo.reload!()
      |> Repo.preload(:rooms)

    active_rooms = active_rooms(group)

    accounting_attrs = %{
      lodging_total_cents: sum_field(active_rooms, :lodging_total_cents),
      deposit_due_cents: sum_field(active_rooms, :deposit_due_cents),
      deposit_paid_cents: held_cash_for_group(group.id),
      credit_paid_cents: held_credit_for_group(group.id),
      refunded_cents: cash_group_disposition_total(group.id, @refunded_disposition),
      retained_cents: cash_group_disposition_total(group.id, @retained_disposition),
      cash_converted_to_credit_cents:
        cash_group_disposition_total(group.id, @converted_disposition)
    }

    group
    |> GroupReservation.update_changeset(Map.merge(accounting_attrs, attrs))
    |> Repo.update!()
  end

  defp update_changed_groups_accounting!(%GroupReservation{} = addressed_group, changed_group_ids) do
    changed_group_ids
    |> MapSet.put(addressed_group.id)
    |> Enum.reduce(nil, fn group_id, updated_addressed_group ->
      group = Repo.get!(GroupReservation, group_id)
      updated_group = update_group_accounting!(group, %{revision: group.revision + 1})

      if group_id == addressed_group.id do
        updated_group
      else
        updated_addressed_group
      end
    end)
  end

  defp held_cash_for_group(group_id) do
    query =
      from allocation in CashAllocation,
        join: room in assoc(allocation, :group_room),
        where: allocation.group_reservation_id == ^group_id,
        where: allocation.disposition == ^@held_disposition,
        where: room.status == ^@active_status,
        select: coalesce(sum(allocation.amount_cents), 0)

    Repo.one(query)
  end

  defp held_credit_for_group(group_id) do
    query =
      from application in HotelCreditApplication,
        join: room in assoc(application, :group_room),
        where: application.group_reservation_id == ^group_id,
        where: application.status == ^@held_credit_status,
        where: room.status == ^@active_status,
        select: coalesce(sum(application.amount_cents), 0)

    Repo.one(query)
  end

  defp held_funding_for_group(%GroupReservation{} = group) do
    held_cash_for_group(group.id) + held_credit_for_group(group.id)
  end

  defp cash_group_disposition_total(group_id, disposition) do
    query =
      from allocation in CashAllocation,
        where: allocation.group_reservation_id == ^group_id,
        where: allocation.disposition == ^disposition,
        select: coalesce(sum(allocation.amount_cents), 0)

    Repo.one(query)
  end

  defp cash_disposition_total_query(disposition) do
    from allocation in CashAllocation,
      where: allocation.disposition == ^disposition,
      select: coalesce(sum(allocation.amount_cents), 0)
  end

  defp held_cash_for_payment(payment_operation_id) do
    query =
      from allocation in CashAllocation,
        join: room in assoc(allocation, :group_room),
        join: group in assoc(allocation, :group_reservation),
        where: allocation.payment_operation_id == ^payment_operation_id,
        where: allocation.disposition == ^@held_disposition,
        where: room.status == ^@active_status,
        where: group.status == ^@active_status,
        select: coalesce(sum(allocation.amount_cents), 0)

    Repo.one(query)
  end

  defp reduction_within_held_cash?(amount_cents, held_cents) do
    if amount_cents <= held_cents do
      :ok
    else
      :reduction_exceeds_held_cash
    end
  end

  defp reduce_held_cash(payment_operation_id, amount_cents) do
    {_remaining_cents, changed_group_ids} =
      payment_operation_id
      |> held_cash_allocations_for_payment_reverse()
      |> Enum.reduce_while({amount_cents, MapSet.new()}, fn allocation,
                                                            {remaining_cents, changed_group_ids} ->
        next_changed_group_ids = MapSet.put(changed_group_ids, allocation.group_reservation_id)

        cond do
          remaining_cents == allocation.amount_cents ->
            allocation
            |> CashAllocation.changeset(%{disposition: @reduced_disposition})
            |> Repo.update!()

            {:halt, {0, next_changed_group_ids}}

          remaining_cents < allocation.amount_cents ->
            allocation
            |> CashAllocation.changeset(%{
              amount_cents: allocation.amount_cents - remaining_cents
            })
            |> Repo.update!()

            insert_cash_allocation!(
              allocation.group_reservation,
              allocation.group_room,
              payment_operation_id,
              @reduced_disposition,
              remaining_cents,
              allocation.allocation_order,
              transferred: allocation.transferred
            )

            {:halt, {0, next_changed_group_ids}}

          true ->
            allocation
            |> CashAllocation.changeset(%{disposition: @reduced_disposition})
            |> Repo.update!()

            {:cont, {remaining_cents - allocation.amount_cents, next_changed_group_ids}}
        end
      end)

    changed_group_ids
  end

  defp held_cash_allocations_for_payment_reverse(payment_operation_id) do
    CashAllocation
    |> join(:inner, [allocation], room in assoc(allocation, :group_room))
    |> join(:inner, [allocation, room], group in assoc(allocation, :group_reservation))
    |> where([allocation], allocation.payment_operation_id == ^payment_operation_id)
    |> where([allocation], allocation.disposition == ^@held_disposition)
    |> where([allocation, room, group], room.status == ^@active_status)
    |> where([allocation, room, group], group.status == ^@active_status)
    |> order_by([allocation], desc: allocation.allocation_order, desc: allocation.id)
    |> preload([allocation, room, group], group_room: room, group_reservation: group)
    |> Repo.all()
  end

  defp charge_back_cash_allocations(payment_operation_id) do
    allocations =
      CashAllocation
      |> where([allocation], allocation.payment_operation_id == ^payment_operation_id)
      |> where(
        [allocation],
        allocation.disposition in [
          ^@held_disposition,
          ^@refunded_disposition,
          ^@retained_disposition,
          ^@converted_disposition
        ]
      )
      |> Repo.all()

    Enum.each(allocations, fn allocation ->
      allocation
      |> CashAllocation.changeset(%{disposition: @charged_back_disposition})
      |> Repo.update!()
    end)

    allocations
    |> Enum.map(& &1.group_reservation_id)
    |> MapSet.new()
  end

  defp revoke_converted_credit_entitlements(payment_operation_id) do
    HotelCreditEntitlement
    |> where([entitlement], entitlement.payment_operation_id == ^payment_operation_id)
    |> where([entitlement], entitlement.charged_back_cents < entitlement.entitled_cents)
    |> preload(:hotel_credit_lot)
    |> Repo.all()
    |> Enum.each(&revoke_credit_entitlement/1)

    :ok
  end

  defp revoke_credit_entitlement(entitlement) do
    unreversed_cents = entitlement.entitled_cents - entitlement.charged_back_cents
    lot = Repo.reload!(entitlement.hotel_credit_lot)
    revoked_available_cents = min(lot.remaining_cents, unreversed_cents)
    unrecovered_cents = unreversed_cents - revoked_available_cents

    lot
    |> HotelCreditLot.changeset(%{
      remaining_cents: lot.remaining_cents - revoked_available_cents,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered_cents
    })
    |> Repo.update!()

    entitlement
    |> HotelCreditEntitlement.changeset(%{
      charged_back_cents: entitlement.charged_back_cents + unreversed_cents
    })
    |> Repo.update!()
  end

  defp active_applied_credit_for_lot(lot_id) do
    query =
      from application in HotelCreditApplication,
        join: room in assoc(application, :group_room),
        join: group in assoc(application, :group_reservation),
        where: application.hotel_credit_lot_id == ^lot_id,
        where: application.status == ^@held_credit_status,
        where: room.status == ^@active_status,
        where: group.status == ^@active_status,
        select: coalesce(sum(application.amount_cents), 0)

    Repo.one(query)
  end

  defp payment_statement(%PartnerOperation{} = payment) do
    result = stored_result(payment)

    totals =
      CashAllocation
      |> where([allocation], allocation.payment_operation_id == ^payment.operation_id)
      |> group_by([allocation], allocation.disposition)
      |> select([allocation], {allocation.disposition, coalesce(sum(allocation.amount_cents), 0)})
      |> Repo.all()
      |> Map.new()

    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: result.group_id,
      recorded_cents: result.amount_cents,
      held_cents: Map.get(totals, @held_disposition, 0),
      refunded_cents: Map.get(totals, @refunded_disposition, 0),
      retained_cents: Map.get(totals, @retained_disposition, 0),
      converted_to_credit_cents: Map.get(totals, @converted_disposition, 0),
      reduced_cents: Map.get(totals, @reduced_disposition, 0),
      charged_back_cents: Map.get(totals, @charged_back_disposition, 0)
    }

    if transferred_payment?(payment.operation_id) do
      Map.put(statement, :held_by_group, held_cash_by_group(payment.operation_id))
    else
      statement
    end
  end

  defp transferred_payment?(payment_operation_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        where: allocation.transferred == true
    )
  end

  defp held_cash_by_group(payment_operation_id) do
    CashAllocation
    |> join(:inner, [allocation], group in assoc(allocation, :group_reservation))
    |> where([allocation], allocation.payment_operation_id == ^payment_operation_id)
    |> where([allocation], allocation.disposition == ^@held_disposition)
    |> group_by([allocation, group], group.group_id)
    |> order_by([allocation, group], asc: group.group_id)
    |> select([allocation, group], %{
      group_id: group.group_id,
      amount_cents: coalesce(sum(allocation.amount_cents), 0)
    })
    |> Repo.all()
  end

  defp cash_payment_operation(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      payment ->
        if applied_cash_payment?(payment) do
          {:ok, payment}
        else
          {:error, :not_cash_payment}
        end
    end
  end

  defp applied_cash_payment?(%PartnerOperation{operation_type: "record_cash_payment"} = payment) do
    case stored_result(payment) do
      %{status: "applied", group_id: group_id, amount_cents: amount_cents}
      when is_binary(group_id) and is_integer(amount_cents) ->
        true

      _result ->
        false
    end
  end

  defp applied_cash_payment?(_payment), do: false

  defp payment_group_id(payment), do: stored_result(payment).group_id

  defp active_group?(%GroupReservation{status: @active_status}), do: :ok
  defp active_group?(_group), do: :group_not_active

  defp valid_transfer_groups?(source_group, destination_group) do
    cond do
      source_group.id == destination_group.id -> :invalid_transfer
      source_group.guest_id != destination_group.guest_id -> :invalid_transfer
      true -> :ok
    end
  end

  defp active_transfer_group?(%GroupReservation{status: @active_status}), do: :ok
  defp active_transfer_group?(group), do: {:group_not_active, group}

  defp valid_payment_amount?(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: :ok

  defp valid_payment_amount?(_amount_cents), do: :invalid_amount

  defp payment_within_outstanding?(group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      :payment_exceeds_outstanding
    end
  end

  defp transfer_within_held_funding?(group, amount_cents) do
    if amount_cents <= held_funding_for_group(group) do
      :ok
    else
      :transfer_exceeds_held_funding
    end
  end

  defp transfer_within_outstanding?(group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      :transfer_exceeds_outstanding
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", @cash_refund_method) do
      @cash_refund_method -> {:ok, @cash_refund_method}
      @hotel_credit_refund_method -> {:ok, @hotel_credit_refund_method}
      _value -> :invalid_operation
    end
  end

  defp refund_method_available?(group, occurred_on, @hotel_credit_refund_method) do
    if refundable_cancellation?(group, occurred_on) do
      :ok
    else
      :refund_method_not_available
    end
  end

  defp refund_method_available?(_group, _occurred_on, @cash_refund_method), do: :ok

  defp selected_active_rooms(%GroupReservation{} = group, operation) do
    with {:ok, room_ids} <- required_room_ids(operation) do
      group = Repo.preload(group, :rooms)
      active_rooms = active_rooms(group)
      active_room_ids = MapSet.new(Enum.map(active_rooms, & &1.room_id))

      if Enum.all?(room_ids, &MapSet.member?(active_room_ids, &1)) do
        selected = Enum.filter(active_rooms, &(&1.room_id in room_ids))
        {:ok, selected}
      else
        :invalid_rooms
      end
    end
  end

  defp required_room_ids(operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &(is_binary(&1) and &1 != "")) and
             length(Enum.uniq(room_ids)) == length(room_ids) do
          {:ok, room_ids}
        else
          :invalid_rooms
        end

      {:ok, _room_ids} ->
        :invalid_rooms

      :error ->
        :invalid_operation
    end
  end

  defp settle_rooms(group, rooms, operation_id, occurred_on, refund_method) do
    refundable? = refundable_cancellation?(group, occurred_on)
    room_ids = Enum.map(rooms, & &1.id)
    cash_allocations = held_cash_allocations_for_rooms(group.id, room_ids)
    cash_cents = sum_field(cash_allocations, :amount_cents)

    {cash_disposition, refunded_cents, retained_cents, converted_cash_cents, credit_issued_cents} =
      cash_settlement_for_room_cents(cash_cents, refund_method, refundable?)

    reclassify_cash_allocations(cash_allocations, cash_disposition)

    if cash_disposition == @converted_disposition do
      issue_hotel_credit(group, operation_id, occurred_on, cash_allocations, credit_issued_cents)
    end

    settle_applied_credit(room_ids, occurred_on, refundable?)
    cancel_room_records(rooms)

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      converted_cash_cents: converted_cash_cents,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp cash_settlement_for_room_cents(cash_cents, @cash_refund_method, true) do
    {@refunded_disposition, cash_cents, 0, 0, 0}
  end

  defp cash_settlement_for_room_cents(cash_cents, @hotel_credit_refund_method, true) do
    credit_issued_cents = cash_cents + credit_bonus_cents(cash_cents)
    {@converted_disposition, 0, 0, cash_cents, credit_issued_cents}
  end

  defp cash_settlement_for_room_cents(cash_cents, _refund_method, false) do
    {@retained_disposition, 0, cash_cents, 0, 0}
  end

  defp issue_hotel_credit(_group, _operation_id, _occurred_on, _cash_allocations, 0), do: :ok

  defp issue_hotel_credit(
         group,
         operation_id,
         occurred_on,
         cash_allocations,
         credit_issued_cents
       ) do
    lot =
      %HotelCreditLot{}
      |> HotelCreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    cash_allocations
    |> Enum.sort_by(& &1.allocation_order)
    |> Enum.reduce(0, fn allocation, running_principal ->
      new_running_principal = running_principal + allocation.amount_cents

      entitled_cents =
        credit_value_cents(new_running_principal) - credit_value_cents(running_principal)

      %HotelCreditEntitlement{}
      |> HotelCreditEntitlement.changeset(%{
        hotel_credit_lot_id: lot.id,
        payment_operation_id: allocation.payment_operation_id,
        principal_cents: allocation.amount_cents,
        entitled_cents: entitled_cents,
        charged_back_cents: 0
      })
      |> Repo.insert!()

      new_running_principal
    end)

    :ok
  end

  defp credit_value_cents(cash_cents), do: cash_cents + credit_bonus_cents(cash_cents)

  defp settle_applied_credit(room_ids, occurred_on, true) do
    applications = held_credit_applications_for_rooms(room_ids)

    applications
    |> Enum.group_by(& &1.hotel_credit_lot_id)
    |> Enum.each(fn {_lot_id, applications} ->
      amount_cents = sum_field(applications, :amount_cents)
      lot = hd(applications).hotel_credit_lot
      restore_credit_to_lot(lot, amount_cents, occurred_on)
    end)

    Enum.each(applications, &update_credit_application_status!(&1, @restored_credit_status))

    :ok
  end

  defp settle_applied_credit(room_ids, _occurred_on, false) do
    room_ids
    |> held_credit_applications_for_rooms()
    |> Enum.each(&update_credit_application_status!(&1, @consumed_credit_status))

    :ok
  end

  defp restore_credit_to_lot(lot, amount_cents, occurred_on) do
    lot = Repo.reload!(lot)
    unrecovered_clawback_cents = lot.unrecovered_clawback_cents || 0
    absorbed_cents = min(unrecovered_clawback_cents, amount_cents)
    restorable_cents = amount_cents - absorbed_cents

    remaining_cents =
      if Date.compare(lot.expires_on, occurred_on) == :lt do
        lot.remaining_cents
      else
        lot.remaining_cents + restorable_cents
      end

    lot
    |> HotelCreditLot.changeset(%{
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: unrecovered_clawback_cents - absorbed_cents
    })
    |> Repo.update!()

    :ok
  end

  defp credit_lots_covering(guest_id, amount_cents, on_date) do
    lots = available_credit_lots(guest_id, on_date)

    if sum_field(lots, :remaining_cents) >= amount_cents do
      {:ok, lots}
    else
      :insufficient_credit
    end
  end

  defp consume_credit_lots(group, lots, operation_id, amount_cents) do
    capacities = active_room_capacities(group)

    Enum.reduce_while(capacities, {amount_cents, lots, next_allocation_order()}, fn {room,
                                                                                     capacity_cents},
                                                                                    {remaining_cents,
                                                                                     current_lots,
                                                                                     allocation_order} ->
      amount_for_room = min(capacity_cents, remaining_cents)

      {next_lots, next_allocation_order} =
        consume_credit_lots_for_room(
          group,
          room,
          operation_id,
          amount_for_room,
          current_lots,
          allocation_order
        )

      next_remaining_cents = remaining_cents - amount_for_room

      case next_remaining_cents do
        0 -> {:halt, {0, next_lots, next_allocation_order}}
        _ -> {:cont, {next_remaining_cents, next_lots, next_allocation_order}}
      end
    end)

    :ok
  end

  defp consume_credit_lots_for_room(_group, _room, _operation_id, 0, lots, allocation_order),
    do: {lots, allocation_order}

  defp consume_credit_lots_for_room(
         group,
         room,
         operation_id,
         amount_cents,
         [lot | rest],
         allocation_order
       ) do
    amount_from_lot = min(lot.remaining_cents, amount_cents)

    {updated_lot, next_allocation_order} =
      if amount_from_lot > 0 do
        lot
        |> HotelCreditLot.changeset(%{remaining_cents: lot.remaining_cents - amount_from_lot})
        |> Repo.update!()

        insert_credit_application!(
          group,
          room,
          lot.id,
          operation_id,
          amount_from_lot,
          allocation_order
        )

        {%{lot | remaining_cents: lot.remaining_cents - amount_from_lot}, allocation_order + 1}
      else
        {lot, allocation_order}
      end

    case amount_cents - amount_from_lot do
      0 ->
        {[updated_lot | rest], next_allocation_order}

      remaining_cents ->
        {next_rest, final_allocation_order} =
          consume_credit_lots_for_room(
            group,
            room,
            operation_id,
            remaining_cents,
            rest,
            next_allocation_order
          )

        {[updated_lot | next_rest], final_allocation_order}
    end
  end

  defp available_credit_lots(guest_id, on_date) do
    HotelCreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on >= ^on_date)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> Repo.all()
  end

  defp credit_liability_cents(on_date) do
    available_credit_query =
      from lot in HotelCreditLot,
        where: lot.remaining_cents > 0,
        where: lot.expires_on >= ^on_date,
        select: coalesce(sum(lot.remaining_cents), 0)

    active_applied_credit_query =
      from application in HotelCreditApplication,
        join: room in assoc(application, :group_room),
        join: group in assoc(application, :group_reservation),
        where: application.status == ^@held_credit_status,
        where: room.status == ^@active_status,
        where: group.status == ^@active_status,
        select: coalesce(sum(application.amount_cents), 0)

    Repo.one(available_credit_query) + Repo.one(active_applied_credit_query)
  end

  defp credit_shortfall_cents do
    HotelCreditLot
    |> where([lot], lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, active_applied_credit_for_lot(lot.id))
    end)
  end

  defp refundable_cancellation?(%GroupReservation{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp policy_version(%GroupReservation{policy_version: policy_version})
       when policy_version in [
              @flex_14_policy_version,
              @flex_30_policy_version,
              @advance_policy_version
            ],
       do: policy_version

  defp policy_version(%GroupReservation{} = group) do
    policy_version_for(group.rate_plan, group.booked_on)
  end

  defp policy_version_for(@flexible_rate_plan, booked_on) do
    if Date.compare(booked_on, @flex_30_cutover) == :lt do
      @flex_14_policy_version
    else
      @flex_30_policy_version
    end
  end

  defp policy_version_for(@advance_purchase_rate_plan, _booked_on), do: @advance_policy_version

  defp refundable_until(group), do: refundable_until(group, policy_version(group))

  defp refundable_until(group, @flex_14_policy_version), do: Date.add(group.arrival_on, -14)
  defp refundable_until(group, @flex_30_policy_version), do: Date.add(group.arrival_on, -30)
  defp refundable_until(_group, @advance_policy_version), do: nil

  defp nullable_date(nil), do: nil
  defp nullable_date(%Date{} = date), do: Date.to_iso8601(date)

  defp outstanding_deposit_cents(%GroupReservation{status: @cancelled_status}), do: 0

  defp outstanding_deposit_cents(%GroupReservation{} = group) do
    group = Repo.preload(group, :rooms)
    totals = room_totals(group)

    active_rooms(group)
    |> Enum.reduce(0, fn room, total ->
      paid_cents = room_paid_cents(totals.cash, room) + room_paid_cents(totals.credit, room)
      total + room.deposit_due_cents - paid_cents
    end)
  end

  defp expected_revision(operation) do
    expected_revision(operation, "expected_revision")
  end

  defp expected_revision(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_operation
      :error -> {:ok, nil}
    end
  end

  defp revision_matches?(operation, group, field) do
    case expected_revision(operation, field) do
      {:ok, nil} ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:stale_revision, group, expected_revision}

      :invalid_operation ->
        :invalid_operation
    end
  end

  defp stale_revision_rejection(operation_id, group, expected_revision) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected_revision,
      actual_revision: group.revision
    }
  end

  defp stored_result(%PartnerOperation{result_json: result_json}) when is_binary(result_json) do
    Jason.decode!(result_json, keys: :atoms)
  end

  defp stored_result(%PartnerOperation{result_json: nil}), do: nil

  defp canonical_json(value) when is_map(value) do
    fields =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, field_value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(field_value)
      end)

    "{" <> fields <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    items = Enum.map_join(value, ",", &canonical_json/1)
    "[" <> items <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _value -> nil
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp rejection(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: code}
  end

  defp rejection(operation_id, code, group_id) do
    operation_id
    |> rejection(code)
    |> Map.put(:group_id, group_id)
  end

  defp changeset_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
