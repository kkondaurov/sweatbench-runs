defmodule GroupStay.Reservations do
  @moduledoc """
  The group-deposit domain and its transactional partner operations.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashPayment,
    CreditLotCashContribution,
    GroupCreditPayment,
    GroupReservation,
    GroupRoom,
    HotelCreditLot,
    PartnerOperation,
    RoomFundingAllocation
  }

  @active "active"
  @cancelled "cancelled"
  @cash "cash"
  @credit "credit"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_change_on ~D[2027-01-01]
  @operation_retry_attempts 5

  @doc "Processes partner operations in their submitted order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group in the API representation, or `nil` when it does not exist."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(GroupReservation, partner_group_id: group_id) do
      nil -> nil
      group -> group_for_api(group)
    end
  end

  def fetch_group(_group_id), do: nil

  @doc "Returns the originally stored result for a partner operation, or `nil`."
  def fetch_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def fetch_operation(_operation_id), do: nil

  @doc "Returns the current reconciliation statement for one recorded cash payment."
  def fetch_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      _operation ->
        case Repo.get_by(CashPayment, payment_operation_id: payment_operation_id) do
          nil ->
            {:error, :payment_not_reconcilable}

          payment ->
            group = Repo.get!(GroupReservation, payment.group_reservation_id)

            statement = %{
              payment_operation_id: payment.payment_operation_id,
              original_group_id: group.partner_group_id,
              recorded_cents: payment.recorded_cents,
              held_cents: payment.held_cents,
              refunded_cents: payment.refunded_cents,
              retained_cents: payment.retained_cents,
              converted_to_credit_cents: payment.converted_to_credit_cents,
              reduced_cents: payment.reduced_cents,
              charged_back_cents: payment.charged_back_cents
            }

            statement =
              if payment.transfer_participated do
                Map.put(statement, :held_by_group, held_cash_by_group(payment))
              else
                statement
              end

            {:ok, statement}
        end
    end
  end

  def fetch_payment(_payment_operation_id), do: {:error, :operation_not_found}

  @doc "Returns finance totals across reservations, including active credit and clawbacks."
  def ledger_totals(as_of \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          cash_held_cents: active_room_sum(:cash_paid_cents),
          cash_refunded_cents: group_sum(:cash_refunded_cents),
          cash_retained_cents: group_sum(:cash_retained_cents),
          cash_converted_to_credit_cents: group_sum(:cash_converted_to_credit_cents),
          cash_reduced_cents: group_sum(:cash_reduced_cents),
          cash_charged_back_cents: group_sum(:cash_charged_back_cents),
          credit_liability_cents: available_credit_total(as_of) + applied_credit_total(),
          credit_shortfall_cents: credit_shortfall_total()
        }
      end)

    totals
  end

  @doc "Returns a guest's unexpired, available hotel-credit lots as of a calendar date."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  defp process_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> process_durable_operation(operation, operation_id)
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp process_durable_operation(operation, operation_id, attempts \\ 0) do
    fingerprint = payload_fingerprint(operation)

    result =
      Repo.transaction(
        fn ->
          case Repo.get_by(PartnerOperation, operation_id: operation_id) do
            nil ->
              process_new_durable_operation(operation, operation_id, fingerprint)

            stored_operation ->
              replay_or_reject_conflict(stored_operation, operation_id, fingerprint)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, response} ->
        response

      {:error, :retry} when attempts < @operation_retry_attempts ->
        process_durable_operation(operation, operation_id, attempts + 1)

      {:error, :retry} ->
        raise "could not durably process partner operation #{inspect(operation_id)}"
    end
  end

  defp process_new_durable_operation(operation, operation_id, fingerprint) do
    case create_operation_record(operation, operation_id, fingerprint) do
      {:ok, stored_operation} ->
        case execute_domain_operation(operation, operation_id) do
          :retry ->
            Repo.rollback(:retry)

          result ->
            result = json_result(result)

            case finalize_operation_record(stored_operation, result) do
              {:ok, _updated_operation} -> result
              {:error, _changeset} -> Repo.rollback(:retry)
            end
        end

      {:error, _changeset} ->
        Repo.rollback(:retry)
    end
  end

  defp create_operation_record(operation, operation_id, fingerprint) do
    %PartnerOperation{}
    |> PartnerOperation.create_changeset(%{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      submitted_payload: operation,
      payload_fingerprint: fingerprint
    })
    |> Repo.insert()
  end

  defp finalize_operation_record(stored_operation, result) do
    stored_operation
    |> Ecto.Changeset.change(result: result)
    |> Repo.update()
  end

  defp replay_or_reject_conflict(stored_operation, operation_id, fingerprint) do
    if stored_operation.payload_fingerprint == fingerprint do
      stored_operation.result || raise "stored partner operation is missing its result"
    else
      %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  # The operation record is outside this savepoint so handled rejections are remembered while all
  # their domain writes are discarded. Unexpected exceptions still escape and roll everything back.
  defp execute_domain_operation(operation, operation_id) do
    Repo.query!("SAVEPOINT partner_operation_domain")

    case apply_domain_operation(operation, operation_id) do
      {:ok, attributes} ->
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        Map.merge(%{operation_id: operation_id, status: "applied"}, attributes)

      {:rejected, code, attributes} ->
        rollback_domain_savepoint()
        rejected(operation, code, attributes)

      :retry ->
        rollback_domain_savepoint()
        :retry
    end
  end

  defp rollback_domain_savepoint do
    Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
    Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
  end

  defp apply_domain_operation(operation, operation_id) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation, operation_id)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation, operation_id)
      "cancel_rooms" -> cancel_rooms(operation, operation_id)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _ -> reject("invalid_operation")
    end
  end

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         false <-
           Repo.exists?(
             from(group in GroupReservation, where: group.partner_group_id == ^group_id)
           ),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation),
         {:ok, lodging_total_cents, deposit_due_cents, room_totals} <-
           totals(arrival_on, departure_on, rate_plan, rooms) do
      attributes = %{
        partner_group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version_for(rate_plan, booked_on),
        status: @active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        outstanding_deposit_cents: deposit_due_cents,
        revision: 1
      }

      with {:ok, group} <-
             %GroupReservation{}
             |> GroupReservation.changeset(attributes)
             |> Repo.insert(),
           {:ok, _rooms} <- insert_rooms(group, room_totals) do
        {:ok,
         %{group_id: group_id, deposit_due_cents: deposit_due_cents, revision: group.revision}}
      else
        {:error, changeset} ->
          if duplicate_group_id?(changeset),
            do: reject("group_already_exists", %{group_id: group_id}),
            else: reject("invalid_operation")
      end
    else
      true ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_already_exists", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :invalid_stay} ->
        reject("invalid_stay")

      {:error, :invalid_rate_plan} ->
        reject("invalid_rate_plan")

      {:error, :invalid_rooms} ->
        reject("invalid_rooms")
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, _occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount_cents),
           {:ok, payment} <- create_cash_payment(group, operation_id, amount_cents),
           :ok <- allocate_cash(group, payment, amount_cents),
           {:ok, updated_group} <- refresh_group_totals(group, expected_revision) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_exceeds_outstanding} ->
          reject("payment_exceeds_outstanding", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp reschedule_group(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, new_arrival_on} <- new_arrival_date(operation),
           :ok <- arrival_after_operation(new_arrival_on, occurred_on),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               arrival_on: new_arrival_on,
               departure_on:
                 Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           policy_version: group_policy_version(updated_group),
           refundable_until: refundable_until_for_api(updated_group),
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_stay} ->
          reject("invalid_stay", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp cancel_group(operation, operation_id) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, refund_method} <- refund_method(operation),
           rooms when rooms != [] <- active_rooms(group),
           {:ok, settlement, updated_group} <-
             settle_rooms(
               group,
               rooms,
               operation_id,
               occurred_on,
               refund_method,
               expected_revision
             ) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        [] ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :refund_method_not_available} ->
          reject("refund_method_not_available", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp cancel_rooms(operation, operation_id) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, refund_method} <- refund_method(operation),
           {:ok, rooms} <- cancellation_rooms(group, operation),
           {:ok, settlement, updated_group} <-
             settle_rooms(
               group,
               rooms,
               operation_id,
               occurred_on,
               refund_method,
               expected_revision
             ) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           cancelled_room_ids: Enum.map(rooms, & &1.room_id),
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_rooms} ->
          reject("invalid_rooms", %{group_id: group.partner_group_id})

        {:error, :refund_method_not_available} ->
          reject("refund_method_not_available", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp apply_hotel_credit(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount_cents),
           {:ok, payments} <- consume_hotel_credit(group, amount_cents, occurred_on),
           :ok <- allocate_credit(group, payments),
           {:ok, updated_group} <- refresh_group_totals(group, expected_revision) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_exceeds_outstanding} ->
          reject("payment_exceeds_outstanding", %{group_id: group.partner_group_id})

        {:error, :insufficient_credit} ->
          reject("insufficient_credit", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp transfer_deposit(operation) do
    with {:ok, source_group_id} <- required_string(operation, "source_group_id"),
         {:ok, source_group} <- find_group(source_group_id),
         {:ok, destination_group_id} <- required_string(operation, "destination_group_id"),
         {:ok, destination_group} <- find_group(destination_group_id),
         {:ok, source_expected_revision} <- expected_revision(operation),
         :ok <- revision_matches(source_group, source_expected_revision),
         {:ok, destination_expected_revision} <- destination_expected_revision(operation),
         :ok <- revision_matches(destination_group, destination_expected_revision),
         :ok <- valid_transfer_groups(source_group, destination_group),
         :ok <- transfer_group_active(source_group),
         :ok <- transfer_group_active(destination_group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- transfer_within_held_funding(source_group, amount_cents),
         :ok <- transfer_within_outstanding(destination_group, amount_cents),
         {:ok, chunks} <- move_funding(source_group, destination_group, amount_cents),
         :ok <- mark_transferred_cash_payments(chunks),
         {:ok, updated_source_group, updated_destination_group} <-
           refresh_transferred_groups(
             source_group,
             destination_group,
             source_expected_revision,
             destination_expected_revision
           ) do
      {:ok,
       %{
         source_group_id: source_group.partner_group_id,
         destination_group_id: destination_group.partner_group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: updated_source_group.outstanding_deposit_cents,
         destination_outstanding_deposit_cents:
           updated_destination_group.outstanding_deposit_cents,
         source_revision: updated_source_group.revision,
         destination_revision: updated_destination_group.revision
       }}
    else
      :error ->
        reject("invalid_operation")

      {:error, :group_not_found, group_id} ->
        reject("group_not_found", %{group_id: group_id})

      {:error, :stale_revision, group, expected_revision} ->
        reject("stale_revision", %{
          group_id: group.partner_group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })

      {:error, :invalid_transfer} ->
        reject("invalid_transfer")

      {:error, :group_not_active, group} ->
        reject("group_not_active", %{group_id: group.partner_group_id})

      {:error, :invalid_amount} ->
        reject("invalid_amount")

      {:error, :transfer_exceeds_held_funding} ->
        reject("transfer_exceeds_held_funding")

      {:error, :transfer_exceeds_outstanding} ->
        reject("transfer_exceeds_outstanding")

      {:error, {:stale_update, group, expected_revision, actual_revision}} ->
        stale_update_rejection(group, expected_revision, actual_revision)

      :retry ->
        :retry
    end
  end

  defp reduce_cash_payment(operation) do
    with_payment_target(operation, :reduction, fn payment, group, expected_revision ->
      with {:ok, amount_cents} <- payment_amount(operation),
           :ok <- reducible(payment),
           :ok <- reduction_within_held(payment, amount_cents),
           {:ok, affected_group_ids} <- remove_cash_allocations(payment, amount_cents),
           {:ok, _payment} <-
             update_cash_payment(payment, %{
               held_cents: payment.held_cents - amount_cents,
               reduced_cents: payment.reduced_cents + amount_cents
             }),
           {:ok, updated_group} <-
             refresh_payment_groups(group, expected_revision, affected_group_ids, %{
               cash_reduced_cents: group.cash_reduced_cents + amount_cents
             }) do
        {:ok,
         %{
           payment_operation_id: payment.payment_operation_id,
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_not_reducible} ->
          reject("payment_not_reducible", %{group_id: group.partner_group_id})

        {:error, :reduction_exceeds_held_cash} ->
          reject("reduction_exceeds_held_cash", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)

        :retry ->
          :retry
      end
    end)
  end

  defp charge_back_payment(operation) do
    with_payment_target(operation, :chargeback, fn payment, group, expected_revision ->
      with :ok <- chargeable(payment),
           {:ok, affected_group_ids} <- remove_cash_allocations(payment, payment.held_cents),
           :ok <- revoke_converted_credit(payment),
           charged_back_cents <- cash_payment_chargeback_amount(payment),
           {:ok, _payment} <-
             update_cash_payment(payment, %{
               held_cents: 0,
               refunded_cents: 0,
               retained_cents: 0,
               converted_to_credit_cents: 0,
               charged_back_cents: payment.charged_back_cents + charged_back_cents
             }),
           {:ok, updated_group} <-
             refresh_payment_groups(group, expected_revision, affected_group_ids, %{
               cash_refunded_cents: group.cash_refunded_cents - payment.refunded_cents,
               cash_retained_cents: group.cash_retained_cents - payment.retained_cents,
               cash_converted_to_credit_cents:
                 group.cash_converted_to_credit_cents - payment.converted_to_credit_cents,
               cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents
             }) do
        {:ok,
         %{
           payment_operation_id: payment.payment_operation_id,
           group_id: group.partner_group_id,
           charged_back_cents: charged_back_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        {:error, :payment_not_chargeable} ->
          reject("payment_not_chargeable", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)

        :retry ->
          :retry
      end
    end)
  end

  defp with_payment_target(operation, action, callback) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         %PartnerOperation{} <- Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      case Repo.get_by(CashPayment, payment_operation_id: payment_operation_id) do
        nil ->
          rejection =
            if action == :reduction, do: "payment_not_reducible", else: "payment_not_chargeable"

          reject(rejection)

        payment ->
          group = Repo.get!(GroupReservation, payment.group_reservation_id)

          with {:ok, expected_revision} <- expected_revision(operation),
               :ok <- revision_matches(group, expected_revision) do
            callback.(payment, group, expected_revision)
          else
            :error ->
              reject("invalid_operation")

            {:error, :stale_revision, stale_group, stale_expected_revision} ->
              reject("stale_revision", %{
                group_id: stale_group.partner_group_id,
                expected_revision: stale_expected_revision,
                actual_revision: stale_group.revision
              })
          end
      end
    else
      nil -> reject("operation_not_found")
      :error -> reject("invalid_operation")
    end
  end

  defp with_group_at_current_revision(operation, callback) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         %GroupReservation{} = group <- Repo.get_by(GroupReservation, partner_group_id: group_id),
         {:ok, expected_revision} <- expected_revision(operation),
         :ok <- revision_matches(group, expected_revision) do
      callback.(group, expected_revision)
    else
      nil ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_not_found", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :stale_revision, group, expected_revision} ->
        reject("stale_revision", %{
          group_id: group.partner_group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp find_group(group_id) do
    case Repo.get_by(GroupReservation, partner_group_id: group_id) do
      nil -> {:error, :group_not_found, group_id}
      group -> {:ok, group}
    end
  end

  defp destination_expected_revision(operation) do
    optional_revision(operation, "destination_expected_revision")
  end

  defp valid_transfer_groups(source_group, destination_group) do
    if source_group.id == destination_group.id or
         source_group.guest_id != destination_group.guest_id,
       do: {:error, :invalid_transfer},
       else: :ok
  end

  defp transfer_group_active(group) do
    case active(group) do
      :ok -> :ok
      {:error, :group_not_active} -> {:error, :group_not_active, group}
    end
  end

  defp transfer_within_held_funding(group, amount_cents) do
    if held_funding_cents(group) >= amount_cents,
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding}
  end

  defp transfer_within_outstanding(group, amount_cents) do
    if group.outstanding_deposit_cents >= amount_cents,
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding}
  end

  defp held_funding_cents(group) do
    Repo.one(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where: room.group_reservation_id == ^group.id and room.status == ^@active,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  defp move_funding(source_group, destination_group, amount_cents) do
    with {:ok, chunks} <- draw_source_funding(source_group, amount_cents),
         :ok <- allocate_transferred_funding(destination_group, chunks) do
      {:ok, chunks}
    end
  end

  defp draw_source_funding(group, amount_cents) do
    allocations =
      Repo.all(
        from(allocation in RoomFundingAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where: room.group_reservation_id == ^group.id and room.status == ^@active,
          order_by: [desc: allocation.id],
          select: {allocation, room}
        )
      )

    allocations
    |> Enum.reduce_while({:ok, amount_cents, []}, fn {allocation, room},
                                                     {:ok, remaining, chunks} ->
      moved_cents = min(remaining, allocation.amount_cents)

      with :ok <- remove_room_funding(room, allocation.funding_type, moved_cents),
           :ok <- shrink_or_delete_allocation(allocation, moved_cents) do
        chunk = %{
          funding_type: allocation.funding_type,
          amount_cents: moved_cents,
          cash_payment_id: allocation.cash_payment_id,
          group_credit_payment_id: allocation.group_credit_payment_id
        }

        if moved_cents == remaining do
          {:halt, {:ok, 0, Enum.reverse([chunk | chunks])}}
        else
          {:cont, {:ok, remaining - moved_cents, [chunk | chunks]}}
        end
      else
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, 0, chunks} -> {:ok, chunks}
      _ -> :error
    end
  end

  defp allocate_transferred_funding(destination_group, chunks) do
    chunks
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case allocate_transferred_chunk(destination_group, chunk) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp allocate_transferred_chunk(destination_group, chunk) do
    allocate_funding(active_rooms(destination_group), chunk.amount_cents, fn room, amount_cents ->
      with :ok <- add_room_funding(room, chunk.funding_type, amount_cents),
           {:ok, _allocation} <-
             Repo.insert(
               %RoomFundingAllocation{}
               |> Ecto.Changeset.change(
                 %{
                   group_room_id: room.id,
                   funding_type: chunk.funding_type,
                   amount_cents: amount_cents
                 }
                 |> Map.merge(funding_provenance(chunk))
               )
             ) do
        :ok
      else
        {:error, _changeset} -> :error
        :error -> :error
      end
    end)
  end

  defp funding_provenance(%{funding_type: @cash, cash_payment_id: payment_id}),
    do: %{cash_payment_id: payment_id}

  defp funding_provenance(%{funding_type: @credit, group_credit_payment_id: payment_id}),
    do: %{group_credit_payment_id: payment_id}

  defp remove_room_funding(room, @cash, amount_cents) do
    update_room_funding(room, :cash_paid_cents, -amount_cents)
  end

  defp remove_room_funding(room, @credit, amount_cents) do
    update_room_funding(room, :credit_paid_cents, -amount_cents)
  end

  defp add_room_funding(room, @cash, amount_cents) do
    update_room_funding(room, :cash_paid_cents, amount_cents)
  end

  defp add_room_funding(room, @credit, amount_cents) do
    update_room_funding(room, :credit_paid_cents, amount_cents)
  end

  defp update_room_funding(room, field, delta) do
    case Repo.update(Ecto.Changeset.change(room, %{field => Map.fetch!(room, field) + delta})) do
      {:ok, _room} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp mark_transferred_cash_payments(chunks) do
    payment_ids =
      chunks
      |> Enum.filter(&(&1.funding_type == @cash))
      |> Enum.map(& &1.cash_payment_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if payment_ids == [] do
      :ok
    else
      {_, _} =
        Repo.update_all(
          from(payment in CashPayment, where: payment.id in ^payment_ids),
          set: [transfer_participated: true]
        )

      :ok
    end
  end

  defp refresh_transferred_groups(
         source_group,
         destination_group,
         source_expected_revision,
         destination_expected_revision
       ) do
    case refresh_group_totals(source_group, source_expected_revision) do
      {:ok, updated_source_group} ->
        case refresh_group_totals(destination_group, destination_expected_revision) do
          {:ok, updated_destination_group} ->
            {:ok, updated_source_group, updated_destination_group}

          {:error, {:stale_update, actual_revision}} ->
            if is_integer(destination_expected_revision),
              do:
                {:error,
                 {:stale_update, destination_group, destination_expected_revision,
                  actual_revision}},
              else: :retry
        end

      {:error, {:stale_update, actual_revision}} ->
        if is_integer(source_expected_revision),
          do: {:error, {:stale_update, source_group, source_expected_revision, actual_revision}},
          else: :retry
    end
  end

  defp refresh_payment_groups(original_group, expected_revision, affected_group_ids, attributes) do
    other_group_ids = MapSet.delete(affected_group_ids, original_group.id) |> MapSet.to_list()

    case refresh_group_totals(original_group, expected_revision, attributes) do
      {:ok, updated_original_group} ->
        other_group_ids
        |> Enum.sort()
        |> Enum.reduce_while(:ok, fn group_id, :ok ->
          group = Repo.get!(GroupReservation, group_id)

          case refresh_group_totals(group, nil) do
            {:ok, _updated_group} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, :retry}
          end
        end)
        |> case do
          :ok -> {:ok, updated_original_group}
          :retry -> :retry
        end

      {:error, {:stale_update, actual_revision}} ->
        {:error, {:stale_update, actual_revision}}
    end
  end

  defp update_group(group, _expected_revision, attributes) do
    group
    |> Ecto.Changeset.change(attributes)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok, updated_group}

      {:error, _changeset} ->
        actual_revision =
          Repo.one(
            from(current_group in GroupReservation,
              where: current_group.id == ^group.id,
              select: current_group.revision
            )
          ) || group.revision

        {:error, {:stale_update, actual_revision}}
    end
  end

  defp refresh_group_totals(group, expected_revision, additional_attributes \\ %{}) do
    totals =
      Repo.one(
        from(room in GroupRoom,
          where: room.group_reservation_id == ^group.id and room.status == ^@active,
          select: %{
            active_rooms: count(room.id),
            lodging_total_cents: coalesce(sum(room.lodging_total_cents), 0),
            deposit_due_cents: coalesce(sum(room.deposit_due_cents), 0),
            cash_paid_cents: coalesce(sum(room.cash_paid_cents), 0),
            credit_paid_cents: coalesce(sum(room.credit_paid_cents), 0)
          }
        )
      )

    active? = totals.active_rooms > 0

    attributes =
      Map.merge(
        %{
          status: if(active?, do: @active, else: @cancelled),
          lodging_total_cents: totals.lodging_total_cents,
          deposit_due_cents: totals.deposit_due_cents,
          deposit_paid_cents: totals.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents,
          outstanding_deposit_cents:
            totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents
        },
        additional_attributes
      )

    update_group(group, expected_revision, attributes)
  end

  defp stale_update_rejection(group, expected_revision, actual_revision)
       when is_integer(expected_revision) do
    reject("stale_revision", %{
      group_id: group.partner_group_id,
      expected_revision: expected_revision,
      actual_revision: actual_revision
    })
  end

  defp stale_update_rejection(_group, nil, _actual_revision), do: :retry

  defp group_for_api(group) do
    rooms = all_rooms(group)

    %{
      group_id: group.partner_group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents,
      policy_version: group_policy_version(group),
      refundable_until: refundable_until_for_api(group)
    }
  end

  defp all_rooms(group) do
    Repo.all(
      from(room in GroupRoom,
        where: room.group_reservation_id == ^group.id,
        order_by: [asc: room.position]
      )
    )
  end

  defp active_rooms(group) do
    Repo.all(
      from(room in GroupRoom,
        where: room.group_reservation_id == ^group.id and room.status == ^@active,
        order_by: [asc: room.position]
      )
    )
  end

  defp cancellation_rooms(group, operation) do
    with {:ok, room_ids} <- room_ids(operation),
         rooms <- active_rooms(group),
         rooms_by_id <- Map.new(rooms, &{&1.room_id, &1}),
         true <- Enum.all?(room_ids, &Map.has_key?(rooms_by_id, &1)) do
      requested = MapSet.new(room_ids)
      {:ok, Enum.filter(rooms, &MapSet.member?(requested, &1.room_id))}
    else
      _ -> {:error, :invalid_rooms}
    end
  end

  defp insert_rooms(group, room_totals) do
    room_totals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, inserted_rooms} ->
      attributes = %{
        group_reservation_id: group.id,
        position: position,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        status: @active,
        lodging_total_cents: room.lodging_total_cents,
        deposit_due_cents: room.deposit_due_cents,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      case Repo.insert(%GroupRoom{} |> Ecto.Changeset.change(attributes)) do
        {:ok, inserted_room} -> {:cont, {:ok, [inserted_room | inserted_rooms]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp create_cash_payment(group, operation_id, amount_cents) do
    %CashPayment{}
    |> Ecto.Changeset.change(%{
      payment_operation_id: operation_id,
      group_reservation_id: group.id,
      recorded_cents: amount_cents,
      held_cents: amount_cents
    })
    |> Repo.insert()
  end

  defp update_cash_payment(payment, attributes) do
    payment
    |> Ecto.Changeset.change(attributes)
    |> Repo.update()
  end

  defp held_cash_by_group(payment) do
    Repo.all(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        join: group in GroupReservation,
        on: group.id == room.group_reservation_id,
        where:
          allocation.cash_payment_id == ^payment.id and allocation.funding_type == ^@cash and
            room.status == ^@active,
        group_by: group.partner_group_id,
        order_by: [asc: group.partner_group_id],
        select: %{group_id: group.partner_group_id, amount_cents: sum(allocation.amount_cents)}
      )
    )
  end

  defp allocate_cash(group, payment, amount_cents) do
    allocate_funding(active_rooms(group), amount_cents, fn room, amount ->
      with {:ok, _room} <-
             Repo.update(
               Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + amount)
             ),
           {:ok, _allocation} <-
             Repo.insert(
               %RoomFundingAllocation{}
               |> Ecto.Changeset.change(%{
                 group_room_id: room.id,
                 funding_type: @cash,
                 amount_cents: amount,
                 cash_payment_id: payment.id
               })
             ) do
        :ok
      else
        {:error, _changeset} -> :error
      end
    end)
  end

  defp allocate_credit(group, payments) do
    Enum.reduce_while(payments, :ok, fn payment, :ok ->
      case allocate_credit_payment(group, payment) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp allocate_credit_payment(group, payment) do
    allocate_funding(active_rooms(group), payment.amount_cents, fn room, amount ->
      with {:ok, _room} <-
             Repo.update(
               Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + amount)
             ),
           {:ok, _allocation} <-
             Repo.insert(
               %RoomFundingAllocation{}
               |> Ecto.Changeset.change(%{
                 group_room_id: room.id,
                 funding_type: @credit,
                 amount_cents: amount,
                 group_credit_payment_id: payment.id
               })
             ) do
        :ok
      else
        {:error, _changeset} -> :error
      end
    end)
  end

  defp allocate_funding(rooms, amount_cents, callback) do
    rooms
    |> Enum.reduce_while({:ok, amount_cents}, fn room, {:ok, remaining} ->
      available = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      amount = min(remaining, max(available, 0))

      case if(amount == 0, do: :ok, else: callback.(room, amount)) do
        :ok when amount == remaining -> {:halt, {:ok, 0}}
        :ok -> {:cont, {:ok, remaining - amount}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, 0} -> :ok
      {:ok, _remaining} -> :error
      :error -> :error
    end
  end

  defp settle_rooms(group, rooms, operation_id, occurred_on, refund_method, expected_revision) do
    cash_allocations = cash_allocations_for_rooms(rooms)
    credit_allocations = credit_allocations_for_rooms(rooms)
    cash_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)

    with {:ok, settlement} <-
           cancellation_settlement(group, occurred_on, refund_method, cash_cents),
         {:ok, credit_lot} <-
           issue_cancellation_credit(group, operation_id, occurred_on, settlement),
         :ok <- settle_cash_allocations(cash_allocations, settlement, credit_lot),
         :ok <- settle_credit_allocations(credit_allocations, occurred_on, settlement.refundable?),
         :ok <- cancel_room_records(rooms),
         {:ok, updated_group} <-
           refresh_group_totals(
             group,
             expected_revision,
             settlement_group_attributes(group, settlement)
           ) do
      {:ok, settlement, updated_group}
    end
  end

  defp cancellation_settlement(group, occurred_on, refund_method, cash_cents) do
    refundable? = refundable?(group, occurred_on)

    cond do
      refund_method == :hotel_credit and not refundable? ->
        {:error, :refund_method_not_available}

      refundable? and refund_method == :hotel_credit ->
        {:ok,
         %{
           refundable?: true,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_cents: cash_cents,
           credit_issued_cents: cash_credit_value(cash_cents),
           cash_disposition: :converted
         }}

      refundable? ->
        {:ok,
         %{
           refundable?: true,
           refunded_cents: cash_cents,
           retained_cents: 0,
           cash_converted_cents: 0,
           credit_issued_cents: 0,
           cash_disposition: :refunded
         }}

      true ->
        {:ok,
         %{
           refundable?: false,
           refunded_cents: 0,
           retained_cents: cash_cents,
           cash_converted_cents: 0,
           credit_issued_cents: 0,
           cash_disposition: :retained
         }}
    end
  end

  defp settlement_group_attributes(group, settlement) do
    %{
      cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
      cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.cash_converted_cents
    }
  end

  defp cash_allocations_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from(allocation in RoomFundingAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.funding_type == ^@cash,
        order_by: [asc: allocation.id]
      )
    )
  end

  defp credit_allocations_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from(allocation in RoomFundingAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.funding_type == ^@credit,
        order_by: [asc: allocation.id]
      )
    )
  end

  defp issue_cancellation_credit(_group, _operation_id, _occurred_on, %{credit_issued_cents: 0}),
    do: {:ok, nil}

  defp issue_cancellation_credit(group, operation_id, occurred_on, settlement) do
    %HotelCreditLot{}
    |> Ecto.Changeset.change(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: settlement.credit_issued_cents,
      expires_on: Date.add(occurred_on, 366),
      unrecovered_clawback_cents: 0
    })
    |> Repo.insert()
  end

  defp settle_cash_allocations(allocations, settlement, credit_lot) do
    allocations
    |> Enum.reduce_while(:ok, fn allocation, :ok ->
      result =
        with :ok <- update_cash_disposition(allocation, settlement.cash_disposition),
             :ok <- maybe_add_credit_contribution(credit_lot, allocation),
             {:ok, _allocation} <- Repo.delete(allocation) do
          :ok
        else
          _ -> :error
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, :error}
    end)
  end

  defp update_cash_disposition(%RoomFundingAllocation{cash_payment_id: nil}, _disposition),
    do: :ok

  defp update_cash_disposition(allocation, disposition) do
    payment = Repo.get!(CashPayment, allocation.cash_payment_id)

    attributes =
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
            converted_to_credit_cents: payment.converted_to_credit_cents + allocation.amount_cents
          }
      end

    case update_cash_payment(payment, attributes) do
      {:ok, _payment} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp maybe_add_credit_contribution(nil, _allocation), do: :ok

  defp maybe_add_credit_contribution(credit_lot, allocation) do
    # An unattributed legacy allocation deliberately remains a nil payment contribution. It is
    # senior when future payment entitlements are calculated, but cannot itself be charged back.
    position =
      Repo.aggregate(
        from(contribution in CreditLotCashContribution,
          where: contribution.hotel_credit_lot_id == ^credit_lot.id
        ),
        :count
      )

    case Repo.insert(
           %CreditLotCashContribution{}
           |> Ecto.Changeset.change(%{
             hotel_credit_lot_id: credit_lot.id,
             cash_payment_id: allocation.cash_payment_id,
             amount_cents: allocation.amount_cents,
             funding_position: position
           })
         ) do
      {:ok, _contribution} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp settle_credit_allocations(allocations, occurred_on, refundable?) do
    allocations
    |> Enum.group_by(& &1.group_credit_payment_id)
    |> Enum.reduce_while(:ok, fn {credit_payment_id, payment_allocations}, :ok ->
      amount_cents = Enum.sum_by(payment_allocations, & &1.amount_cents)
      payment = Repo.get!(GroupCreditPayment, credit_payment_id)

      with :ok <-
             if(refundable?,
               do: restore_credit_payment(payment, amount_cents, occurred_on),
               else: :ok
             ),
           {deleted_count, _} <-
             Repo.delete_all(
               from(allocation in RoomFundingAllocation,
                 where: allocation.id in ^Enum.map(payment_allocations, & &1.id)
               )
             ),
           true <- deleted_count == length(payment_allocations),
           :ok <- reduce_credit_payment(payment, amount_cents) do
        {:cont, :ok}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp restore_credit_payment(payment, amount_cents, occurred_on) do
    lot = Repo.get!(HotelCreditLot, payment.hotel_credit_lot_id)
    absorbed = min(amount_cents, lot.unrecovered_clawback_cents)
    remaining_to_restore = amount_cents - absorbed

    attributes = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

    attributes =
      if remaining_to_restore > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
        Map.put(attributes, :remaining_cents, lot.remaining_cents + remaining_to_restore)
      else
        attributes
      end

    case Repo.update(Ecto.Changeset.change(lot, attributes)) do
      {:ok, _lot} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp reduce_credit_payment(payment, amount_cents) do
    if payment.amount_cents == amount_cents do
      case Repo.delete(payment) do
        {:ok, _payment} -> :ok
        {:error, _changeset} -> :error
      end
    else
      case Repo.update(
             Ecto.Changeset.change(payment, amount_cents: payment.amount_cents - amount_cents)
           ) do
        {:ok, _payment} -> :ok
        {:error, _changeset} -> :error
      end
    end
  end

  defp cancel_room_records(rooms) do
    rooms
    |> Enum.reduce_while(:ok, fn room, :ok ->
      case Repo.update(
             Ecto.Changeset.change(room,
               status: @cancelled,
               cash_paid_cents: 0,
               credit_paid_cents: 0
             )
           ) do
        {:ok, _room} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, :error}
      end
    end)
  end

  defp remove_cash_allocations(_payment, 0), do: {:ok, MapSet.new()}

  defp remove_cash_allocations(payment, amount_cents) do
    allocations =
      Repo.all(
        from(allocation in RoomFundingAllocation,
          join: room in GroupRoom,
          on: room.id == allocation.group_room_id,
          where:
            allocation.cash_payment_id == ^payment.id and allocation.funding_type == ^@cash and
              room.status == ^@active,
          order_by: [desc: allocation.id],
          select: {allocation, room}
        )
      )

    allocations
    |> Enum.reduce_while({:ok, amount_cents, MapSet.new()}, fn {allocation, room},
                                                               {:ok, remaining, group_ids} ->
      amount = min(remaining, allocation.amount_cents)

      with {:ok, _room} <-
             Repo.update(
               Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - amount)
             ),
           :ok <- shrink_or_delete_allocation(allocation, amount) do
        group_ids = MapSet.put(group_ids, room.group_reservation_id)

        if amount == remaining,
          do: {:halt, {:ok, 0, group_ids}},
          else: {:cont, {:ok, remaining - amount, group_ids}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, 0, group_ids} -> {:ok, group_ids}
      _ -> :error
    end
  end

  defp shrink_or_delete_allocation(allocation, amount_cents)
       when allocation.amount_cents == amount_cents do
    case Repo.delete(allocation) do
      {:ok, _allocation} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp shrink_or_delete_allocation(allocation, amount_cents) do
    case Repo.update(
           Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount_cents)
         ) do
      {:ok, _allocation} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp consume_hotel_credit(group, amount_cents, occurred_on) do
    lots = available_credit_lots(group.guest_id, occurred_on)

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      lots
      |> Enum.reduce_while({:ok, amount_cents, []}, fn lot, {:ok, remaining, payments} ->
        amount_from_lot = min(remaining, lot.remaining_cents)

        case consume_credit_lot(group, lot, amount_from_lot) do
          {:ok, payment} when remaining == amount_from_lot ->
            {:halt, {:ok, 0, [payment | payments]}}

          {:ok, payment} ->
            {:cont, {:ok, remaining - amount_from_lot, [payment | payments]}}

          :error ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, 0, payments} -> {:ok, Enum.reverse(payments)}
        :error -> :error
      end
    end
  end

  defp consume_credit_lot(group, lot, amount_cents) do
    with {:ok, _updated_lot} <-
           Repo.update(
             Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - amount_cents)
           ),
         {:ok, payment} <-
           Repo.insert(
             %GroupCreditPayment{}
             |> Ecto.Changeset.change(%{
               group_reservation_id: group.id,
               hotel_credit_lot_id: lot.id,
               amount_cents: amount_cents
             })
           ) do
      {:ok, payment}
    else
      {:error, _changeset} -> :error
    end
  end

  defp reducible(%CashPayment{held_cents: held_cents}) when held_cents > 0, do: :ok
  defp reducible(_payment), do: {:error, :payment_not_reducible}

  defp reduction_within_held(payment, amount_cents) when amount_cents <= payment.held_cents,
    do: :ok

  defp reduction_within_held(_payment, _amount_cents), do: {:error, :reduction_exceeds_held_cash}

  defp chargeable(payment) do
    if payment.charged_back_cents > 0 or cash_payment_chargeback_amount(payment) == 0 do
      {:error, :payment_not_chargeable}
    else
      :ok
    end
  end

  defp cash_payment_chargeback_amount(payment) do
    payment.held_cents + payment.refunded_cents + payment.retained_cents +
      payment.converted_to_credit_cents
  end

  defp revoke_converted_credit(%CashPayment{converted_to_credit_cents: 0}), do: :ok

  defp revoke_converted_credit(payment) do
    contributions =
      Repo.all(
        from(contribution in CreditLotCashContribution,
          where: contribution.cash_payment_id == ^payment.id,
          order_by: [asc: contribution.hotel_credit_lot_id, asc: contribution.funding_position]
        )
      )

    contributions
    |> Enum.group_by(& &1.hotel_credit_lot_id)
    |> Enum.reduce_while(:ok, fn {lot_id, payment_contributions}, :ok ->
      lot = Repo.get!(HotelCreditLot, lot_id)
      entitlement = payment_entitlement(lot_id, payment.id)
      revoked = min(entitlement, lot.remaining_cents)
      unrecovered = entitlement - revoked

      case Repo.update(
             Ecto.Changeset.change(lot,
               remaining_cents: lot.remaining_cents - revoked,
               unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
             )
           ) do
        {:ok, _lot} when payment_contributions != [] -> {:cont, :ok}
        {:error, _changeset} -> {:halt, :error}
      end
    end)
  end

  defp payment_entitlement(lot_id, payment_id) do
    Repo.all(
      from(contribution in CreditLotCashContribution,
        where: contribution.hotel_credit_lot_id == ^lot_id,
        order_by: [asc: contribution.funding_position, asc: contribution.id]
      )
    )
    |> Enum.reduce({0, 0}, fn contribution, {running_cash, entitlement} ->
      next_running_cash = running_cash + contribution.amount_cents

      next_entitlement =
        if contribution.cash_payment_id == payment_id do
          entitlement + cash_credit_value(next_running_cash) - cash_credit_value(running_cash)
        else
          entitlement
        end

      {next_running_cash, next_entitlement}
    end)
    |> elem(1)
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
    )
  end

  defp available_credit_total(as_of) do
    Repo.one(
      from(lot in HotelCreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
    )
  end

  defp applied_credit_total do
    Repo.one(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where: allocation.funding_type == ^@credit and room.status == ^@active,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  defp credit_shortfall_total do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.unrecovered_clawback_cents > 0,
        select: {lot.id, lot.unrecovered_clawback_cents}
      )
    )
    |> Enum.sum_by(fn {lot_id, unrecovered_clawback_cents} ->
      applied_cents =
        Repo.one(
          from(allocation in RoomFundingAllocation,
            join: room in GroupRoom,
            on: room.id == allocation.group_room_id,
            join: payment in GroupCreditPayment,
            on: payment.id == allocation.group_credit_payment_id,
            where:
              allocation.funding_type == ^@credit and room.status == ^@active and
                payment.hotel_credit_lot_id == ^lot_id,
            select: coalesce(sum(allocation.amount_cents), 0)
          )
        )

      min(unrecovered_clawback_cents, applied_cents)
    end)
  end

  defp active_room_sum(field) do
    Repo.one(
      from(room in GroupRoom,
        where: room.status == ^@active,
        select: coalesce(sum(field(room, ^field)), 0)
      )
    )
  end

  defp group_sum(field) do
    Repo.one(from(group in GroupReservation, select: coalesce(sum(field(group, ^field)), 0)))
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(group) do
    case group_policy_version(group) do
      @flex_14 -> Date.add(group.arrival_on, -14)
      @flex_30 -> Date.add(group.arrival_on, -30)
      @advance_nonrefundable -> nil
    end
  end

  defp refundable_until_for_api(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp group_policy_version(%GroupReservation{policy_version: policy_version})
       when policy_version in [@flex_14, @flex_30, @advance_nonrefundable],
       do: policy_version

  defp group_policy_version(group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_change_on) == :lt, do: @flex_14, else: @flex_30
  end

  defp cash_credit_value(0), do: 0
  defp cash_credit_value(cash_cents), do: cash_cents + div(cash_cents * 10 + 50, 100)

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, :cash}
      {:ok, "cash"} -> {:ok, :cash}
      {:ok, "hotel_credit"} -> {:ok, :hotel_credit}
      {:ok, _refund_method} -> :error
    end
  end

  defp active(%GroupReservation{status: @active}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp payment_within_outstanding(group, amount_cents)
       when amount_cents <= group.outstanding_deposit_cents,
       do: :ok

  defp payment_within_outstanding(_group, _amount_cents),
    do: {:error, :payment_exceeds_outstanding}

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp revision_matches(_group, nil), do: :ok

  defp revision_matches(group, expected_revision) when group.revision == expected_revision,
    do: :ok

  defp revision_matches(group, expected_revision),
    do: {:error, :stale_revision, group, expected_revision}

  defp expected_revision(operation) do
    optional_revision(operation, "expected_revision")
  end

  defp optional_revision(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:ok, nil}
      {:ok, expected_revision} when is_integer(expected_revision) -> {:ok, expected_revision}
      {:ok, _expected_revision} -> :error
    end
  end

  defp operation_date(operation) do
    with {:ok, occurred_on} <- required_string(operation, "occurred_on"),
         {:ok, date} <- parse_date(occurred_on) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- required_string(operation, "arrival_on"),
         {:ok, departure_on} <- required_string(operation, "departure_on"),
         {:ok, arrival_on} <- parse_date(arrival_on),
         {:ok, departure_on} <- parse_date(departure_on),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp new_arrival_date(operation) do
    with {:ok, new_arrival_on} <- required_string(operation, "new_arrival_on"),
         {:ok, date} <- parse_date(new_arrival_on) do
      {:ok, date}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      {:ok, _rate_plan} -> {:error, :invalid_rate_plan}
      :error -> :error
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] -> validate_rooms(rooms)
      {:ok, _rooms} -> {:error, :invalid_rooms}
      :error -> :error
    end
  end

  defp validate_rooms(rooms) do
    rooms
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn
      %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
      {:ok, room_ids, validated_rooms}
      when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 ->
        if MapSet.member?(room_ids, room_id) do
          {:halt, {:error, :invalid_rooms}}
        else
          room = %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
          {:cont, {:ok, MapSet.put(room_ids, room_id), [room | validated_rooms]}}
        end

      _room, _validated ->
        {:halt, {:error, :invalid_rooms}}
    end)
    |> case do
      {:ok, _room_ids, validated_rooms} -> {:ok, Enum.reverse(validated_rooms)}
      {:error, :invalid_rooms} -> {:error, :invalid_rooms}
    end
  end

  defp room_ids(operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &is_binary/1) and
             MapSet.size(MapSet.new(room_ids)) == length(room_ids),
           do: {:ok, room_ids},
           else: {:error, :invalid_rooms}

      _ ->
        {:error, :invalid_rooms}
    end
  end

  defp totals(arrival_on, departure_on, rate_plan, rooms) do
    nights = Date.diff(departure_on, arrival_on)

    room_totals =
      Enum.map(rooms, fn room ->
        lodging_total_cents = room.nightly_rate_cents * nights

        deposit_due_cents =
          case rate_plan do
            @flexible -> rounded_flexible_deposit(lodging_total_cents)
            @advance_purchase -> lodging_total_cents
          end

        Map.merge(room, %{
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents
        })
      end)

    {:ok, Enum.sum_by(room_totals, & &1.lodging_total_cents),
     Enum.sum_by(room_totals, & &1.deposit_due_cents), room_totals}
  end

  defp rounded_flexible_deposit(lodging_total_cents), do: div(lodging_total_cents * 20 + 50, 100)

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}

      :error ->
        :error
    end
  end

  defp required_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  # JSON object keys are unordered, while arrays and scalar JSON values are not. Turning maps
  # into sorted tuples gives equivalent JSON object payloads the same durable fingerprint.
  defp payload_fingerprint(payload) do
    payload
    |> canonical_json_value()
    |> :erlang.term_to_binary()
  end

  defp canonical_json_value(value) when is_map(value) do
    {:object,
     value
     |> Enum.map(fn {key, nested_value} -> {key, canonical_json_value(nested_value)} end)
     |> Enum.sort_by(&elem(&1, 0))}
  end

  defp canonical_json_value(value) when is_list(value),
    do: {:array, Enum.map(value, &canonical_json_value/1)}

  defp canonical_json_value(value), do: {:scalar, value}

  defp json_result(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {json_key(key), json_result(nested_value)} end)
  end

  defp json_result(value) when is_list(value), do: Enum.map(value, &json_result/1)
  defp json_result(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  defp duplicate_group_id?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, options}} ->
      field == :partner_group_id and options[:constraint] == :unique
    end)
  end

  defp reject(code, attributes \\ %{}), do: {:rejected, code, attributes}

  defp rejected(operation, code, attributes \\ %{}) do
    base = Map.merge(%{status: "rejected", code: code}, attributes)

    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> Map.put(base, :operation_id, operation_id)
      :error -> base
    end
  end
end
