defmodule GroupStay.Reservations do
  @moduledoc """
  Domain operations for partner-managed group reservations.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashPaymentDisposition,
    CashPaymentTransfer,
    CreditLot,
    CreditLotCashSource,
    FinanceDailyReport,
    FinanceCashMovement,
    FinanceCashOpening,
    FinanceCreditMovement,
    FinancePeriodClose,
    FinanceReportingStart,
    Group,
    PartnerOperation,
    Room,
    RoomCreditAllocation
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @policy_cutover ~D[2027-01-01]
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted_to_credit "converted_to_credit"
  @reduced "reduced"
  @charged_back "charged_back"
  @finance_reporting_singleton_key "current"

  @cash_movement_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  @credit_movement_fields [
    :issued_cents,
    :expired_cents,
    :consumed_cents,
    :revoked_cents,
    :absorbed_cents
  ]

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        {:ok,
         group |> Repo.preload(rooms: from(r in Room, order_by: r.position)) |> present_group()}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger_totals(on_param \\ nil) do
    with {:ok, on} <- reporting_date(on_param) do
      %{
        cash_held_cents: sum_groups(:cash_paid_cents, status: @active),
        cash_refunded_cents: sum_groups(:cash_refunded_cents),
        cash_retained_cents: sum_groups(:cash_retained_cents),
        cash_converted_to_credit_cents: sum_groups(:cash_converted_to_credit_cents),
        cash_reduced_cents: cash_disposition_total(@reduced),
        cash_charged_back_cents: cash_disposition_total(@charged_back),
        credit_liability_cents:
          available_credit_liability_cents(on) + active_credit_allocation_total_cents(),
        credit_shortfall_cents: credit_shortfall_cents()
      }
    end
  end

  def get_daily_finance_report(date_param) do
    with {:ok, date} <- finance_report_date(date_param),
         {:ok, start} <- get_finance_reporting_start(),
         :ok <- ensure_report_available(date, start.starts_on) do
      {:ok, daily_finance_report(start, date)}
    end
  end

  def get_guest_credit(guest_id, on_param \\ nil)

  def get_guest_credit(guest_id, on_param) when is_binary(guest_id) do
    with {:ok, on} <- reporting_date(on_param) do
      lots = available_credit_lots(guest_id, on)

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
         lots:
           Enum.map(lots, fn lot ->
             %{
               source_operation_id: lot.source_operation_id,
               remaining_cents: lot.remaining_cents,
               expires_on: Date.to_iso8601(lot.expires_on)
             }
           end)
       }}
    end
  end

  def get_guest_credit(_guest_id, _on_param),
    do: {:ok, %{guest_id: nil, available_cents: 0, lots: []}}

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      %PartnerOperation{result: result} when is_map(result) ->
        {:ok, result}

      _missing_or_incomplete ->
        {:error, :operation_not_found}
    end
  end

  def get_operation_result(_operation_id), do: {:error, :operation_not_found}

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        case applied_cash_payment_result(record) do
          {:ok, result} ->
            recorded_cents = map_get(result, "amount_cents")
            dispositions = payment_disposition_totals(payment_operation_id)

            statement = %{
              payment_operation_id: payment_operation_id,
              original_group_id: map_get(result, "group_id"),
              recorded_cents: recorded_cents,
              held_cents: Map.get(dispositions, @held, 0),
              refunded_cents: Map.get(dispositions, @refunded, 0),
              retained_cents: Map.get(dispositions, @retained, 0),
              converted_to_credit_cents: Map.get(dispositions, @converted_to_credit, 0),
              reduced_cents: Map.get(dispositions, @reduced, 0),
              charged_back_cents: Map.get(dispositions, @charged_back, 0)
            }

            statement =
              if cash_payment_transferred?(payment_operation_id) do
                Map.put(statement, :held_by_group, held_cash_by_group(payment_operation_id))
              else
                statement
              end

            {:ok, statement}

          :error ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment_statement(_payment_operation_id), do: {:error, :operation_not_found}

  defp process_operation(%{} = operation) do
    case fetch_operation_id(operation) do
      {:ok, operation_id} -> process_idempotent_operation(operation, operation_id)
      {:reject, _result} -> process_untracked_operation(operation)
    end
  end

  defp process_operation(operation), do: process_untracked_operation(operation)

  defp process_idempotent_operation(operation, operation_id) do
    canonical_payload = canonical_json(operation)

    case Repo.transaction(fn ->
           case reserve_partner_operation(operation, operation_id, canonical_payload) do
             {:reserved, record} ->
               result = apply_operation_result(operation)

               record
               |> change(result: result)
               |> Repo.update!()

               result

             {:existing, record} ->
               if record.canonical_payload == canonical_payload do
                 record.result
               else
                 rejected(operation, "operation_id_conflict")
               end
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp process_untracked_operation(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:reject, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp reserve_partner_operation(operation, operation_id, canonical_payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {inserted_count, _rows} =
      Repo.insert_all(
        PartnerOperation,
        [
          %{
            operation_id: operation_id,
            operation_type: operation_type(operation),
            submitted_payload: operation,
            canonical_payload: canonical_payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: :operation_id
      )

    record = Repo.get_by!(PartnerOperation, operation_id: operation_id)

    case inserted_count do
      1 -> {:reserved, record}
      _already_seen -> {:existing, record}
    end
  end

  defp apply_operation_result(operation) do
    case apply_operation(operation) do
      {:ok, result} -> result
      {:reject, result} -> result
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "start_finance_reporting"} = operation) do
    start_finance_reporting(operation)
  end

  defp apply_operation(%{"type" => "close_finance_period"} = operation) do
    close_finance_period(operation)
  end

  defp apply_operation(%{"type" => "record_cash_payment"} = operation) do
    with_existing_group(operation, fn group -> record_cash_payment(operation, group) end)
  end

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation) do
    with_existing_group(operation, fn group -> apply_hotel_credit(operation, group) end)
  end

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation) do
    with_existing_payment_group(operation, "payment_not_reducible", fn group, payment_record ->
      reduce_cash_payment(operation, group, payment_record)
    end)
  end

  defp apply_operation(%{"type" => "charge_back_payment"} = operation) do
    with_existing_payment_group(operation, "payment_not_chargeable", fn group, payment_record ->
      charge_back_payment(operation, group, payment_record)
    end)
  end

  defp apply_operation(%{"type" => "transfer_deposit"} = operation) do
    transfer_deposit(operation)
  end

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with_existing_group(operation, fn group -> reschedule_group(operation, group) end)
  end

  defp apply_operation(%{"type" => "cancel_rooms"} = operation) do
    with_existing_group(operation, fn group -> cancel_rooms(operation, group) end)
  end

  defp apply_operation(%{"type" => "cancel_group"} = operation) do
    with_existing_group(operation, fn group -> cancel_group(operation, group) end)
  end

  defp apply_operation(operation) when is_map(operation) do
    {:reject, rejected(operation, "invalid_operation")}
  end

  defp apply_operation(_operation) do
    {:reject, rejected(%{}, "invalid_operation")}
  end

  defp open_group(operation) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id"),
         :ok <- ensure_group_available(operation, group_id),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(operation, arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         totals <- calculate_totals(rooms, arrival_on, departure_on, rate_plan),
         {:ok, group} <-
           insert_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: booked_on,
             arrival_on: arrival_on,
             departure_on: departure_on,
             rate_plan: rate_plan,
             policy_version: policy_version_for(rate_plan, booked_on),
             lodging_total_cents: totals.lodging_total_cents,
             deposit_due_cents: totals.deposit_due_cents
           }),
         :ok <- insert_rooms(group, totals.rooms) do
      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp start_finance_reporting(operation) do
    with {:ok, _operation_id} <- fetch_string(operation, "operation_id"),
         {:ok, starts_on} <- fetch_date(operation, "starts_on", "invalid_reporting_date"),
         :ok <- ensure_finance_reporting_not_started(operation),
         {:ok, _start} <- insert_finance_reporting_start(operation, starts_on) do
      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         starts_on: Date.to_iso8601(starts_on)
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp close_finance_period(operation) do
    with {:ok, _operation_id} <- fetch_string(operation, "operation_id"),
         {:ok, period_end_on} <- fetch_date(operation, "period_end_on", "invalid_period"),
         {:ok, start} <- get_finance_reporting_start_for_close(operation),
         :ok <- ensure_valid_period_close(operation, start, period_end_on),
         :ok <- publish_finance_reports_through(start, period_end_on),
         {:ok, _close} <- insert_finance_period_close(operation, period_end_on) do
      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         period_end_on: Date.to_iso8601(period_end_on)
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         outstanding <- outstanding_deposit_cents(group),
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding),
         :ok <- allocate_cash_payment(group, operation_id(operation), amount_cents) do
      updated = refresh_group_summary!(group, revision: group.revision + 1)
      record_cash_movement(operation, updated.property_id, %{received_cents: amount_cents})

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp apply_hotel_credit(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         outstanding <- outstanding_deposit_cents(group),
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding),
         {:ok, lots} <-
           ensure_credit_available(operation, group.guest_id, amount_cents, occurred_on),
         :ok <- allocate_hotel_credit(group, operation_id(operation), lots, amount_cents) do
      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- ensure_future_arrival(operation, group, new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      updated =
        group
        |> change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         new_arrival_on: Date.to_iso8601(updated.arrival_on),
         new_departure_on: Date.to_iso8601(updated.departure_on),
         policy_version: policy_version(updated),
         refundable_until: refundable_until_iso8601(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- fetch_refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(operation, refund_method, refundable) do
      settlement =
        operation
        |> settle_selected_rooms(
          group,
          active_rooms(group),
          refund_method,
          refundable,
          occurred_on
        )

      updated = refresh_group_summary!(group, status: @cancelled, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp cancel_rooms(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- fetch_refund_method(operation),
         {:ok, rooms} <- fetch_active_rooms(operation, group),
         refundable <- refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(operation, refund_method, refundable) do
      settlement =
        operation
        |> settle_selected_rooms(group, rooms, refund_method, refundable, occurred_on)

      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         cancelled_room_ids: Enum.map(rooms, & &1.room_id),
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp reduce_cash_payment(operation, group, payment_record) do
    payment_operation_id = payment_record.operation_id

    with {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         held_cents <- payment_held_cash_cents(payment_operation_id),
         :ok <- ensure_payment_reducible(operation, held_cents),
         :ok <- ensure_reduction_fits(operation, amount_cents, held_cents),
         {:ok, reduction_movements} <-
           reduce_held_payment_cash(payment_operation_id, amount_cents) do
      touched_group_ids = Enum.map(reduction_movements, & &1.reservation_id)
      updated_groups = refresh_changed_groups!(group, touched_group_ids)
      updated = Map.fetch!(updated_groups, group.id)
      record_cash_movements_by_group(operation, reduction_movements, :reduced_cents)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         payment_operation_id: payment_operation_id,
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp charge_back_payment(operation, group, payment_record) do
    payment_operation_id = payment_record.operation_id
    dispositions = payment_disposition_totals(payment_operation_id)
    chargeable_cents = chargeable_payment_cents(dispositions)

    cond do
      Map.get(dispositions, @charged_back, 0) > 0 ->
        {:reject, rejected(operation, "payment_not_chargeable")}

      chargeable_cents <= 0 ->
        {:reject, rejected(operation, "payment_not_chargeable")}

      true ->
        cash_movements = charge_back_payment_dispositions(payment_operation_id)
        credit_movements = revoke_converted_credit_entitlements(payment_operation_id)
        touched_group_ids = Enum.map(cash_movements, & &1.reservation_id)
        updated_groups = refresh_changed_groups!(group, touched_group_ids)
        updated = Map.fetch!(updated_groups, group.id)
        record_chargeback_cash_movements(operation, cash_movements)
        record_credit_movement(operation, credit_movements)

        {:ok,
         %{
           operation_id: operation_id(operation),
           status: "applied",
           payment_operation_id: payment_operation_id,
           group_id: updated.group_id,
           charged_back_cents: chargeable_cents,
           outstanding_deposit_cents: outstanding_deposit_cents(updated),
           revision: updated.revision
         }}
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- require_common_fields(operation),
         {:ok, source_group_id} <- fetch_string(operation, "source_group_id"),
         {:ok, source_group} <- fetch_transfer_group(operation, source_group_id),
         {:ok, destination_group_id} <- fetch_string(operation, "destination_group_id"),
         {:ok, destination_group} <- fetch_transfer_group(operation, destination_group_id),
         :ok <- ensure_fresh_revision(operation, source_group),
         :ok <-
           ensure_fresh_revision(operation, destination_group, "destination_expected_revision"),
         :ok <- ensure_valid_transfer_groups(operation, source_group, destination_group),
         :ok <- ensure_transfer_group_active(operation, source_group),
         :ok <- ensure_transfer_group_active(operation, destination_group),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         :ok <- ensure_transfer_held_funding(operation, source_group, amount_cents),
         :ok <- ensure_transfer_outstanding(operation, destination_group, amount_cents),
         {:ok, transfer_chunks} <-
           move_held_funding(
             source_group,
             destination_group,
             amount_cents,
             operation_id(operation)
           ) do
      updated_source =
        refresh_group_summary!(source_group, revision: source_group.revision + 1)

      updated_destination =
        refresh_group_summary!(destination_group, revision: destination_group.revision + 1)

      record_transfer_cash_movements(
        operation,
        updated_source.property_id,
        updated_destination.property_id,
        transfer_chunks
      )

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         source_group_id: updated_source.group_id,
         destination_group_id: updated_destination.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: outstanding_deposit_cents(updated_source),
         destination_outstanding_deposit_cents: outstanding_deposit_cents(updated_destination),
         source_revision: updated_source.revision,
         destination_revision: updated_destination.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp with_existing_group(operation, callback) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:reject, rejected(operation, "group_not_found")}

        group ->
          case ensure_fresh_revision(operation, group) do
            :ok -> callback.(group)
            {:reject, result} -> {:reject, result}
          end
      end
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp with_existing_payment_group(operation, invalid_payment_code, callback) do
    with :ok <- require_common_fields(operation),
         {:ok, payment_operation_id} <- fetch_string(operation, "payment_operation_id") do
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil ->
          {:reject, rejected(operation, "operation_not_found")}

        payment_record ->
          with {:ok, payment_result} <-
                 payment_result(payment_record, operation, invalid_payment_code),
               {:ok, group_id} <-
                 payment_group_id(payment_result, operation, invalid_payment_code),
               %Group{} = group <- Repo.get_by(Group, group_id: group_id),
               :ok <- ensure_fresh_revision(operation, group) do
            callback.(group, payment_record)
          else
            nil -> {:reject, rejected(operation, "group_not_found")}
            {:reject, result} -> {:reject, result}
          end
      end
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp payment_result(payment_record, operation, invalid_payment_code) do
    case applied_cash_payment_result(payment_record) do
      {:ok, result} -> {:ok, result}
      :error -> {:reject, rejected(operation, invalid_payment_code)}
    end
  end

  defp payment_group_id(result, operation, invalid_payment_code) do
    case map_get(result, "group_id") do
      group_id when is_binary(group_id) and group_id != "" ->
        {:ok, group_id}

      _other ->
        {:reject, rejected(operation, invalid_payment_code)}
    end
  end

  defp require_common_fields(operation) do
    with {:ok, _operation_id} <- fetch_string(operation, "operation_id"),
         {:ok, _occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation") do
      :ok
    else
      {:reject, _result} -> {:reject, rejected(operation, "invalid_operation")}
    end
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :ok
      _group -> {:reject, rejected(operation, "group_already_exists")}
    end
  end

  defp fetch_transfer_group(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:reject, rejected_with_group(operation, "group_not_found", group_id)}
      group -> {:ok, group}
    end
  end

  defp ensure_fresh_revision(operation, group, field \\ "expected_revision") do
    case Map.fetch(operation, field) do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:reject,
         %{
           operation_id: operation_id(operation),
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group) do
    {:reject, rejected(operation, "group_not_active")}
  end

  defp ensure_valid_transfer_groups(operation, source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id ->
        {:reject, rejected(operation, "invalid_transfer")}

      source_group.guest_id != destination_group.guest_id ->
        {:reject, rejected(operation, "invalid_transfer")}

      true ->
        :ok
    end
  end

  defp ensure_transfer_group_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_transfer_group_active(operation, group) do
    {:reject, rejected_with_group(operation, "group_not_active", group.group_id)}
  end

  defp ensure_payment_fits(_operation, _group, amount_cents, outstanding)
       when amount_cents <= outstanding do
    :ok
  end

  defp ensure_payment_fits(operation, _group, _amount_cents, _outstanding) do
    {:reject, rejected(operation, "payment_exceeds_outstanding")}
  end

  defp ensure_future_arrival(operation, _group, new_arrival_on, occurred_on) do
    cond do
      Date.compare(new_arrival_on, occurred_on) == :gt ->
        :ok

      true ->
        {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp ensure_credit_available(operation, guest_id, amount_cents, occurred_on) do
    lots = available_credit_lots(guest_id, occurred_on)
    available_cents = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available_cents >= amount_cents do
      {:ok, lots}
    else
      {:reject, rejected(operation, "insufficient_credit")}
    end
  end

  defp ensure_refund_method_available(operation, @hotel_credit, false) do
    {:reject, rejected(operation, "refund_method_not_available")}
  end

  defp ensure_refund_method_available(_operation, _refund_method, _refundable), do: :ok

  defp ensure_payment_reducible(operation, held_cents) when held_cents <= 0 do
    {:reject, rejected(operation, "payment_not_reducible")}
  end

  defp ensure_payment_reducible(_operation, _held_cents), do: :ok

  defp ensure_reduction_fits(_operation, amount_cents, held_cents)
       when amount_cents <= held_cents do
    :ok
  end

  defp ensure_reduction_fits(operation, _amount_cents, _held_cents) do
    {:reject, rejected(operation, "reduction_exceeds_held_cash")}
  end

  defp ensure_transfer_held_funding(operation, source_group, amount_cents) do
    if held_funding_cents_for_group(source_group.id) >= amount_cents do
      :ok
    else
      {:reject, rejected(operation, "transfer_exceeds_held_funding")}
    end
  end

  defp ensure_transfer_outstanding(operation, destination_group, amount_cents) do
    if outstanding_deposit_cents(destination_group) >= amount_cents do
      :ok
    else
      {:reject, rejected(operation, "transfer_exceeds_outstanding")}
    end
  end

  defp fetch_active_rooms(operation, group) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        active_room_ids =
          group
          |> active_rooms()
          |> Enum.map(& &1.room_id)

        distinct? = Enum.uniq(room_ids) == room_ids
        valid? = Enum.all?(room_ids, &(&1 in active_room_ids))

        if distinct? and valid? do
          selected = MapSet.new(room_ids)

          {:ok,
           group
           |> active_rooms()
           |> Enum.filter(&MapSet.member?(selected, &1.room_id))}
        else
          {:reject, rejected(operation, "invalid_rooms")}
        end

      _other ->
        {:reject, rejected(operation, "invalid_rooms")}
    end
  end

  defp allocate_cash_payment(group, payment_operation_id, amount_cents) do
    sequence = next_funding_sequence()

    group
    |> room_funding_chunks(amount_cents)
    |> Enum.reduce(sequence, fn {room, chunk_cents}, next_sequence ->
      Repo.insert!(%CashPaymentDisposition{
        reservation_id: group.id,
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        disposition: @held,
        amount_cents: chunk_cents,
        sequence: next_sequence
      })

      next_sequence + 1
    end)

    :ok
  end

  defp allocate_hotel_credit(group, source_operation_id, lots, amount_cents) do
    sequence = next_funding_sequence()

    group
    |> room_funding_chunks(amount_cents)
    |> Enum.reduce({lots, sequence}, fn {room, chunk_cents}, {remaining_lots, next_sequence} ->
      allocate_credit_to_room(
        group,
        source_operation_id,
        room,
        chunk_cents,
        remaining_lots,
        next_sequence
      )
    end)

    :ok
  end

  defp move_held_funding(source_group, destination_group, amount_cents, transfer_operation_id) do
    chunks = draw_transfer_chunks(source_group, amount_cents, transfer_operation_id)

    destination_group
    |> destination_room_slots()
    |> allocate_transferred_chunks(destination_group, chunks)

    {:ok, chunks}
  end

  defp draw_transfer_chunks(source_group, amount_cents, transfer_operation_id) do
    source_group.id
    |> held_funding_rows_for_group()
    |> Enum.reduce_while({amount_cents, []}, fn allocation, {remaining_cents, chunks} ->
      drawn_cents = min(allocation.amount_cents, remaining_cents)
      reduce_source_allocation!(allocation, drawn_cents)
      record_cash_transfer_participation!(allocation, transfer_operation_id, drawn_cents)

      chunk = %{allocation | amount_cents: drawn_cents}

      case remaining_cents - drawn_cents do
        0 -> {:halt, {0, chunks ++ [chunk]}}
        next_remaining_cents -> {:cont, {next_remaining_cents, chunks ++ [chunk]}}
      end
    end)
    |> elem(1)
  end

  defp reduce_source_allocation!(%{amount_cents: amount_cents} = allocation, drawn_cents)
       when amount_cents == drawn_cents do
    Repo.delete!(allocation.row)
  end

  defp reduce_source_allocation!(allocation, drawn_cents) do
    allocation.row
    |> change(amount_cents: allocation.amount_cents - drawn_cents)
    |> Repo.update!()
  end

  defp record_cash_transfer_participation!(
         %{kind: :cash, payment_operation_id: payment_operation_id},
         transfer_operation_id,
         amount_cents
       )
       when is_binary(payment_operation_id) and payment_operation_id != "" do
    Repo.insert!(%CashPaymentTransfer{
      payment_operation_id: payment_operation_id,
      transfer_operation_id: transfer_operation_id,
      amount_cents: amount_cents
    })
  end

  defp record_cash_transfer_participation!(_allocation, _transfer_operation_id, _amount_cents) do
    :ok
  end

  defp allocate_transferred_chunks(room_slots, destination_group, chunks) do
    {_slots, _sequence} =
      Enum.reduce(chunks, {room_slots, next_funding_sequence()}, fn chunk, {slots, sequence} ->
        allocate_transferred_chunk(destination_group, chunk, slots, sequence)
      end)

    :ok
  end

  defp allocate_transferred_chunk(destination_group, chunk, room_slots, sequence) do
    allocate_transferred_chunk(
      destination_group,
      chunk,
      chunk.amount_cents,
      room_slots,
      sequence,
      []
    )
  end

  defp allocate_transferred_chunk(_destination_group, _chunk, 0, room_slots, sequence, rebuilt) do
    {Enum.reverse(rebuilt) ++ room_slots, sequence}
  end

  defp allocate_transferred_chunk(
         _destination_group,
         _chunk,
         _amount_cents,
         [],
         _sequence,
         _rebuilt
       ) do
    raise "destination deposit capacity disappeared during transfer"
  end

  defp allocate_transferred_chunk(
         destination_group,
         chunk,
         amount_cents,
         [%{remaining_cents: 0} = room_slot | room_slots],
         sequence,
         rebuilt
       ) do
    allocate_transferred_chunk(destination_group, chunk, amount_cents, room_slots, sequence, [
      room_slot | rebuilt
    ])
  end

  defp allocate_transferred_chunk(
         destination_group,
         chunk,
         amount_cents,
         [%{room: room, remaining_cents: room_remaining_cents} = room_slot | room_slots],
         sequence,
         rebuilt
       ) do
    allocated_cents = min(room_remaining_cents, amount_cents)
    insert_transferred_allocation!(destination_group, room, chunk, allocated_cents, sequence)
    next_room_slot = %{room_slot | remaining_cents: room_remaining_cents - allocated_cents}

    allocate_transferred_chunk(
      destination_group,
      chunk,
      amount_cents - allocated_cents,
      [next_room_slot | room_slots],
      sequence + 1,
      rebuilt
    )
  end

  defp insert_transferred_allocation!(
         destination_group,
         room,
         %{kind: :cash} = chunk,
         amount_cents,
         sequence
       ) do
    Repo.insert!(%CashPaymentDisposition{
      reservation_id: destination_group.id,
      room_id: room.id,
      payment_operation_id: chunk.payment_operation_id,
      disposition: @held,
      amount_cents: amount_cents,
      sequence: sequence
    })
  end

  defp insert_transferred_allocation!(
         destination_group,
         room,
         %{kind: :credit} = chunk,
         amount_cents,
         sequence
       ) do
    Repo.insert!(%RoomCreditAllocation{
      reservation_id: destination_group.id,
      room_id: room.id,
      credit_lot_id: chunk.credit_lot_id,
      source_operation_id: chunk.source_operation_id,
      amount_cents: amount_cents,
      active: true,
      sequence: sequence
    })
  end

  defp allocate_credit_to_room(_group, _source_operation_id, _room, 0, lots, sequence) do
    {lots, sequence}
  end

  defp allocate_credit_to_room(
         group,
         source_operation_id,
         room,
         amount_cents,
         [lot | lots],
         sequence
       ) do
    consumed_cents = min(cents(lot.remaining_cents), amount_cents)

    if consumed_cents == 0 do
      allocate_credit_to_room(group, source_operation_id, room, amount_cents, lots, sequence)
    else
      lot
      |> change(remaining_cents: lot.remaining_cents - consumed_cents)
      |> Repo.update!()

      Repo.insert!(%RoomCreditAllocation{
        reservation_id: group.id,
        room_id: room.id,
        credit_lot_id: lot.id,
        source_operation_id: source_operation_id,
        amount_cents: consumed_cents,
        active: true,
        sequence: sequence
      })

      updated_lot = %{lot | remaining_cents: lot.remaining_cents - consumed_cents}
      remaining_cents = amount_cents - consumed_cents
      next_sequence = sequence + 1

      cond do
        remaining_cents == 0 ->
          {[updated_lot | lots], next_sequence}

        updated_lot.remaining_cents <= 0 ->
          allocate_credit_to_room(
            group,
            source_operation_id,
            room,
            remaining_cents,
            lots,
            next_sequence
          )

        true ->
          allocate_credit_to_room(
            group,
            source_operation_id,
            room,
            remaining_cents,
            [updated_lot | lots],
            next_sequence
          )
      end
    end
  end

  defp settle_selected_rooms(operation, group, rooms, refund_method, refundable, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_rows = held_cash_rows_for_rooms(room_ids)
    credit_settlement = settle_credit_allocations(room_ids, occurred_on, refundable)

    settlement =
      settle_cash_rows(operation, group, cash_rows, refund_method, refundable, occurred_on)

    Enum.each(rooms, fn room ->
      room
      |> change(status: @cancelled)
      |> Repo.update!()
    end)

    record_cash_movement(operation, group.property_id, settlement.cash_movements)

    record_credit_movement(
      operation,
      merge_credit_movements(settlement.credit_movements, credit_settlement)
    )

    settlement
  end

  defp settle_cash_rows(operation, group, cash_rows, @hotel_credit, true, occurred_on) do
    cash_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    credit_issued_cents = credit_issued_cents(cash_cents)

    credit_lot =
      if credit_issued_cents > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id(operation),
          remaining_cents: credit_issued_cents,
          expires_on: credit_expires_on(occurred_on),
          unrecovered_clawback_cents: 0
        })
      end

    if credit_lot do
      create_credit_lot_cash_sources(credit_lot, cash_rows)
    end

    update_cash_rows_disposition(cash_rows, @converted_to_credit, credit_lot)

    %{
      refunded_cents: 0,
      retained_cents: 0,
      credit_issued_cents: credit_issued_cents,
      cash_movements: %{converted_to_credit_cents: cash_cents},
      credit_movements: %{issued_cents: credit_issued_cents}
    }
  end

  defp settle_cash_rows(_operation, _group, cash_rows, @cash, true, _occurred_on) do
    refunded_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    update_cash_rows_disposition(cash_rows, @refunded)

    %{
      refunded_cents: refunded_cents,
      retained_cents: 0,
      credit_issued_cents: 0,
      cash_movements: %{refunded_cents: refunded_cents},
      credit_movements: %{}
    }
  end

  defp settle_cash_rows(_operation, _group, cash_rows, @cash, false, _occurred_on) do
    retained_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    update_cash_rows_disposition(cash_rows, @retained)

    %{
      refunded_cents: 0,
      retained_cents: retained_cents,
      credit_issued_cents: 0,
      cash_movements: %{retained_cents: retained_cents},
      credit_movements: %{}
    }
  end

  defp settle_credit_allocations(room_ids, occurred_on, true) do
    room_ids
    |> active_credit_allocations_for_rooms()
    |> Enum.reduce(zero_credit_movements(), fn allocation, movements ->
      allocation
      |> change(active: false)
      |> Repo.update!()

      allocation.credit_lot_id
      |> restore_credit_to_lot(allocation.amount_cents, occurred_on)
      |> merge_credit_movements(movements)
    end)
  end

  defp settle_credit_allocations(room_ids, _occurred_on, false) do
    consumed_cents =
      room_ids
      |> active_credit_allocations_for_rooms()
      |> Enum.reduce(0, fn allocation, consumed_cents ->
        allocation
        |> change(active: false)
        |> Repo.update!()

        consumed_cents + allocation.amount_cents
      end)

    %{consumed_cents: consumed_cents}
  end

  defp restore_credit_to_lot(credit_lot_id, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, credit_lot_id)
    absorbed_cents = min(cents(lot.unrecovered_clawback_cents), amount_cents)
    restorable_cents = amount_cents - absorbed_cents

    {available_cents, expired_cents} =
      if Date.compare(lot.expires_on, occurred_on) == :gt do
        {restorable_cents, 0}
      else
        {0, restorable_cents}
      end

    lot
    |> change(
      remaining_cents: cents(lot.remaining_cents) + available_cents,
      unrecovered_clawback_cents: cents(lot.unrecovered_clawback_cents) - absorbed_cents
    )
    |> Repo.update!()

    %{
      absorbed_cents: absorbed_cents,
      expired_cents: expired_cents
    }
  end

  defp update_cash_rows_disposition(rows, disposition, credit_lot \\ nil) do
    Enum.each(rows, fn row ->
      row
      |> change(
        disposition: disposition,
        credit_lot_id: credit_lot && credit_lot.id
      )
      |> Repo.update!()
    end)
  end

  defp create_credit_lot_cash_sources(credit_lot, cash_rows) do
    cash_rows
    |> credit_lot_source_principals()
    |> Enum.reduce({0, 1}, fn source, {previous_cash_cents, source_order} ->
      running_cash_cents = previous_cash_cents + source.cash_cents

      credit_cents =
        credit_issued_cents(running_cash_cents) - credit_issued_cents(previous_cash_cents)

      Repo.insert!(%CreditLotCashSource{
        credit_lot_id: credit_lot.id,
        payment_operation_id: source.payment_operation_id,
        cash_cents: source.cash_cents,
        credit_cents: credit_cents,
        source_order: source_order
      })

      {running_cash_cents, source_order + 1}
    end)

    :ok
  end

  defp credit_lot_source_principals(cash_rows) do
    Enum.reduce(cash_rows, [], fn row, sources ->
      case List.last(sources) do
        %{payment_operation_id: payment_operation_id, cash_cents: cash_cents}
        when payment_operation_id == row.payment_operation_id ->
          List.replace_at(sources, -1, %{
            payment_operation_id: payment_operation_id,
            cash_cents: cash_cents + row.amount_cents
          })

        _other ->
          sources ++
            [
              %{
                payment_operation_id: row.payment_operation_id,
                cash_cents: row.amount_cents
              }
            ]
      end
    end)
  end

  defp reduce_held_payment_cash(payment_operation_id, amount_cents) do
    {_remaining_cents, movements} =
      payment_operation_id
      |> held_cash_rows_for_payment()
      |> Enum.reduce_while({amount_cents, []}, fn row, {remaining_cents, movements} ->
        reduced_cents = min(row.amount_cents, remaining_cents)
        movement = %{reservation_id: row.reservation_id, amount_cents: reduced_cents}

        if reduced_cents == row.amount_cents do
          row
          |> change(disposition: @reduced)
          |> Repo.update!()
        else
          row
          |> change(amount_cents: row.amount_cents - reduced_cents)
          |> Repo.update!()

          Repo.insert!(%CashPaymentDisposition{
            reservation_id: row.reservation_id,
            room_id: row.room_id,
            payment_operation_id: row.payment_operation_id,
            disposition: @reduced,
            amount_cents: reduced_cents,
            sequence: row.sequence
          })
        end

        case remaining_cents - reduced_cents do
          0 -> {:halt, {0, movements ++ [movement]}}
          next_remaining_cents -> {:cont, {next_remaining_cents, movements ++ [movement]}}
        end
      end)

    {:ok, movements}
  end

  defp charge_back_payment_dispositions(payment_operation_id) do
    query =
      CashPaymentDisposition
      |> where([disposition], disposition.payment_operation_id == ^payment_operation_id)
      |> where(
        [disposition],
        disposition.disposition in [@held, @refunded, @retained, @converted_to_credit]
      )

    movements =
      query
      |> select([disposition], %{
        reservation_id: disposition.reservation_id,
        disposition: disposition.disposition,
        amount_cents: disposition.amount_cents
      })
      |> Repo.all()

    Repo.update_all(query, set: [disposition: @charged_back])

    movements
  end

  defp revoke_converted_credit_entitlements(payment_operation_id) do
    CreditLotCashSource
    |> where([source], source.payment_operation_id == ^payment_operation_id)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.reduce(zero_credit_movements(), fn source, movements ->
      lot = source.credit_lot
      removed_cents = min(cents(lot.remaining_cents), source.credit_cents)
      unrecovered_cents = source.credit_cents - removed_cents

      lot
      |> change(
        remaining_cents: cents(lot.remaining_cents) - removed_cents,
        unrecovered_clawback_cents: cents(lot.unrecovered_clawback_cents) + unrecovered_cents
      )
      |> Repo.update!()

      merge_credit_movements(%{revoked_cents: removed_cents}, movements)
    end)
  end

  defp validate_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp validate_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        normalize_rooms(operation, rooms)

      _other ->
        {:reject, rejected(operation, "invalid_rooms")}
    end
  end

  defp normalize_rooms(operation, rooms) do
    normalized =
      Enum.reduce_while(rooms, [], fn room, acc ->
        with %{} <- room,
             {:ok, room_id} <- fetch_string(room, "room_id"),
             {:ok, nightly_rate_cents} <-
               fetch_positive_integer(room, "nightly_rate_cents", "invalid_rooms") do
          {:cont, [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents} | acc]}
        else
          _other -> {:halt, :invalid}
        end
      end)

    case normalized do
      :invalid ->
        {:reject, rejected(operation, "invalid_rooms")}

      rooms ->
        rooms = Enum.reverse(rooms)
        room_ids = Enum.map(rooms, & &1.room_id)

        if Enum.uniq(room_ids) == room_ids do
          {:ok, rooms}
        else
          {:reject, rejected(operation, "invalid_rooms")}
        end
    end
  end

  defp validate_rate_plan(operation) do
    case Map.get(operation, "rate_plan") do
      rate_plan when rate_plan in [@flexible, @advance_purchase] ->
        {:ok, rate_plan}

      _other ->
        {:reject, rejected(operation, "invalid_rate_plan")}
    end
  end

  defp calculate_totals(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    Enum.reduce(rooms, %{lodging_total_cents: 0, deposit_due_cents: 0, rooms: []}, fn room,
                                                                                      totals ->
      lodging_cents = room.nightly_rate_cents * nights
      deposit_cents = deposit_for_room(lodging_cents, rate_plan)

      room =
        Map.merge(room, %{lodging_total_cents: lodging_cents, deposit_due_cents: deposit_cents})

      %{
        lodging_total_cents: totals.lodging_total_cents + lodging_cents,
        deposit_due_cents: totals.deposit_due_cents + deposit_cents,
        rooms: totals.rooms ++ [room]
      }
    end)
  end

  defp deposit_for_room(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for_room(lodging_cents, @advance_purchase), do: lodging_cents

  defp refundable?(group, occurred_on) do
    case cancellation_window_days(group) do
      nil ->
        false

      window_days ->
        Date.compare(occurred_on, Date.add(group.arrival_on, -window_days)) != :gt
    end
  end

  defp cancellation_window_days(%Group{} = group) do
    case policy_version(group) do
      @flex_14 -> 14
      @flex_30 -> 30
      @advance_nonrefundable -> nil
      _unknown -> nil
    end
  end

  defp policy_version(%Group{policy_version: nil, rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) in [:eq, :gt] do
      @flex_30
    else
      @flex_14
    end
  end

  defp refundable_until(%Group{} = group) do
    case cancellation_window_days(group) do
      nil -> nil
      window_days -> Date.add(group.arrival_on, -window_days)
    end
  end

  defp refundable_until_iso8601(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp credit_issued_cents(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp credit_expires_on(occurred_on), do: Date.add(occurred_on, 366)

  defp insert_group(attrs) do
    %Group{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      policy_version: attrs.policy_version,
      status: @active,
      lodging_total_cents: attrs.lodging_total_cents,
      deposit_due_cents: attrs.deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      revision: 1
    }
    |> Repo.insert()
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        reservation_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        status: @active,
        lodging_total_cents: room.lodging_total_cents,
        deposit_due_cents: room.deposit_due_cents
      })
    end)

    :ok
  end

  defp present_group(group) do
    room_cash_totals = cash_totals_by_room(group.id)
    room_credit_totals = credit_totals_by_room(group.id)
    totals = group_active_totals(group.id)

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
      refundable_until: refundable_until_iso8601(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room_status(room),
            lodging_total_cents: room_lodging_total_cents(room),
            deposit_due_cents: room_deposit_due_cents(room),
            cash_paid_cents: Map.get(room_cash_totals, room.id, 0),
            credit_paid_cents: Map.get(room_credit_totals, room.id, 0)
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    group.id
    |> group_active_totals()
    |> Map.fetch!(:outstanding_deposit_cents)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp refresh_group_summary!(group, opts) do
    totals = group_active_totals(group.id)
    settlement_totals = group_cash_settlement_totals(group.id)

    status =
      Keyword.get_lazy(opts, :status, fn ->
        if totals.deposit_due_cents == 0 and active_room_count(group.id) == 0 do
          @cancelled
        else
          group.status
        end
      end)

    group
    |> change(
      status: status,
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      cash_refunded_cents: Map.get(settlement_totals, @refunded, 0),
      cash_retained_cents: Map.get(settlement_totals, @retained, 0),
      cash_converted_to_credit_cents: Map.get(settlement_totals, @converted_to_credit, 0),
      revision: Keyword.get(opts, :revision, group.revision)
    )
    |> Repo.update!()
  end

  defp refresh_changed_groups!(addressed_group, changed_group_ids) do
    group_ids =
      [addressed_group.id | changed_group_ids]
      |> Enum.uniq()

    groups =
      Group
      |> where([group], group.id in ^group_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    group_ids
    |> Enum.map(fn group_id ->
      group = Map.fetch!(groups, group_id)
      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {group_id, updated}
    end)
    |> Map.new()
  end

  defp get_finance_reporting_start do
    case Repo.get_by(FinanceReportingStart, singleton_key: @finance_reporting_singleton_key) do
      nil -> {:error, :report_not_available}
      start -> {:ok, start}
    end
  end

  defp get_finance_reporting_start_for_close(operation) do
    case get_finance_reporting_start() do
      {:ok, start} -> {:ok, start}
      {:error, :report_not_available} -> {:reject, rejected(operation, "invalid_period")}
    end
  end

  defp ensure_finance_reporting_not_started(operation) do
    case get_finance_reporting_start() do
      {:ok, _start} -> {:reject, rejected(operation, "reporting_already_started")}
      {:error, :report_not_available} -> :ok
    end
  end

  defp insert_finance_reporting_start(operation, starts_on) do
    start =
      Repo.insert!(%FinanceReportingStart{
        singleton_key: @finance_reporting_singleton_key,
        operation_id: operation_id(operation),
        starts_on: starts_on,
        opening_credit_liability_cents: current_credit_liability_cents(starts_on)
      })

    current_cash_held_by_property()
    |> Enum.each(fn %{property_id: property_id, amount_cents: amount_cents} ->
      Repo.insert!(%FinanceCashOpening{
        finance_reporting_start_id: start.id,
        property_id: property_id,
        opening_held_cents: amount_cents
      })
    end)

    {:ok, start}
  end

  defp ensure_valid_period_close(operation, start, period_end_on) do
    latest_closed_on = latest_finance_period_close_end_on()

    cond do
      Date.compare(period_end_on, start.starts_on) == :lt ->
        {:reject, rejected(operation, "invalid_period")}

      latest_closed_on && Date.compare(period_end_on, latest_closed_on) != :gt ->
        {:reject, rejected(operation, "invalid_period")}

      true ->
        :ok
    end
  end

  defp publish_finance_reports_through(start, period_end_on) do
    first_unclosed_on =
      case latest_finance_period_close_end_on() do
        nil -> start.starts_on
        latest_closed_on -> Date.add(latest_closed_on, 1)
      end

    if Date.compare(first_unclosed_on, period_end_on) != :gt do
      first_unclosed_on
      |> dates_through(period_end_on)
      |> Enum.each(fn date ->
        Repo.insert!(%FinanceDailyReport{
          report_date: date,
          data: build_daily_finance_report(start, date, "closed")
        })
      end)
    end

    :ok
  end

  defp insert_finance_period_close(operation, period_end_on) do
    close =
      Repo.insert!(%FinancePeriodClose{
        operation_id: operation_id(operation),
        period_end_on: period_end_on
      })

    {:ok, close}
  end

  defp ensure_report_available(date, starts_on) do
    if Date.compare(date, starts_on) == :lt do
      {:error, :report_not_available}
    else
      :ok
    end
  end

  defp current_credit_liability_cents(on) do
    available_credit_liability_cents(on) + active_credit_allocation_total_cents()
  end

  defp current_cash_held_by_property do
    CashPaymentDisposition
    |> join(:inner, [disposition], group in Group, on: disposition.reservation_id == group.id)
    |> join(:inner, [disposition, _group], room in Room, on: disposition.room_id == room.id)
    |> where(
      [disposition, group, room],
      disposition.disposition == ^@held and group.status == ^@active and room.status == ^@active
    )
    |> group_by([_disposition, group, _room], group.property_id)
    |> order_by([_disposition, group, _room], asc: group.property_id)
    |> select([disposition, group, _room], %{
      property_id: group.property_id,
      amount_cents: coalesce(sum(disposition.amount_cents), 0)
    })
    |> Repo.all()
    |> Enum.reject(&(&1.amount_cents == 0))
  end

  defp daily_finance_report(start, date) do
    case Repo.get_by(FinanceDailyReport, report_date: date) do
      %FinanceDailyReport{data: data} when is_map(data) ->
        data

      _open_report ->
        build_daily_finance_report(start, date, "open")
    end
  end

  defp build_daily_finance_report(start, date, status) do
    anchor = latest_closed_daily_report_before(date)
    cash = daily_cash_report(start, date, anchor)
    credit = daily_credit_report(start, date, anchor)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash.entries,
      credit: credit.report,
      late_adjustments: %{
        cash: cash.late_adjustments,
        credit: credit.late_adjustments
      }
    }
  end

  defp latest_closed_daily_report_before(date) do
    FinanceDailyReport
    |> where([report], report.report_date < ^date)
    |> order_by([report], desc: report.report_date)
    |> limit(1)
    |> Repo.one()
  end

  defp daily_cash_report(start, date, anchor) do
    anchor_date = anchor && anchor.report_date
    openings = cash_opening_balances(start, anchor)

    movements =
      FinanceCashMovement
      |> finance_movement_window(anchor_date, date)
      |> Repo.all()

    movement_properties =
      movements
      |> Enum.map(& &1.property_id)
      |> MapSet.new()

    openings
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(movement_properties)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      cash_report_entry(property_id, Map.get(openings, property_id, 0), movements, date)
    end)
    |> then(fn reports ->
      %{
        entries:
          reports
          |> Enum.reject(&zero_cash_report_entry?(&1.entry, &1.late_movements))
          |> Enum.map(& &1.entry),
        late_adjustments:
          reports
          |> Enum.reject(&cash_movements_zero?(&1.late_movements))
          |> Enum.map(fn report ->
            %{
              property_id: report.entry.property_id,
              movements: report.late_movements
            }
          end)
      }
    end)
  end

  defp cash_report_entry(property_id, start_opening_cents, movements, date) do
    {before_date, on_date} =
      movements
      |> Enum.filter(&(&1.property_id == property_id))
      |> Enum.split_with(&(Date.compare(&1.posting_date, date) == :lt))

    opening_held_cents =
      start_opening_cents + (before_date |> aggregate_cash_movements() |> cash_balance_delta())

    {late_on_date, ordinary_on_date} = Enum.split_with(on_date, &late_adjustment?/1)
    movement_totals = aggregate_cash_movements(ordinary_on_date)
    late_movements = aggregate_cash_movements(late_on_date)

    %{
      entry: %{
        property_id: property_id,
        opening_held_cents: opening_held_cents,
        movements: movement_totals,
        closing_held_cents:
          opening_held_cents + cash_balance_delta(movement_totals) +
            cash_balance_delta(late_movements)
      },
      late_movements: late_movements
    }
  end

  defp cash_opening_balances(start, nil) do
    FinanceCashOpening
    |> where([opening], opening.finance_reporting_start_id == ^start.id)
    |> select([opening], {opening.property_id, opening.opening_held_cents})
    |> Repo.all()
    |> Map.new()
  end

  defp cash_opening_balances(_start, %FinanceDailyReport{data: data}) do
    data
    |> report_value("cash", [])
    |> Map.new(fn entry ->
      {report_value(entry, "property_id"), report_value(entry, "closing_held_cents", 0)}
    end)
  end

  defp zero_cash_report_entry?(
         %{
           opening_held_cents: opening_held_cents,
           closing_held_cents: closing_held_cents,
           movements: movements
         },
         late_movements
       ) do
    opening_held_cents == 0 and closing_held_cents == 0 and cash_movements_zero?(movements) and
      cash_movements_zero?(late_movements)
  end

  defp daily_credit_report(start, date, anchor) do
    anchor_date = anchor && anchor.report_date
    movements = credit_movements_until(start, date, anchor_date)

    {before_date, on_date} =
      Enum.split_with(movements, &(Date.compare(&1.posting_date, date) == :lt))

    opening_liability_cents =
      credit_opening_liability_cents(start, anchor) +
        (before_date |> aggregate_credit_movements() |> credit_balance_delta())

    {late_on_date, ordinary_on_date} = Enum.split_with(on_date, &late_adjustment?/1)
    movement_totals = aggregate_credit_movements(ordinary_on_date)
    late_movements = aggregate_credit_movements(late_on_date)

    %{
      report: %{
        opening_liability_cents: opening_liability_cents,
        movements: movement_totals,
        closing_liability_cents:
          opening_liability_cents + credit_balance_delta(movement_totals) +
            credit_balance_delta(late_movements)
      },
      late_adjustments: late_movements
    }
  end

  defp credit_opening_liability_cents(start, nil), do: start.opening_credit_liability_cents

  defp credit_opening_liability_cents(_start, %FinanceDailyReport{data: data}) do
    data
    |> report_value("credit", %{})
    |> report_value("closing_liability_cents", 0)
  end

  defp credit_movements_until(start, date, after_date) do
    persisted_movements =
      FinanceCreditMovement
      |> finance_movement_window(after_date, date)
      |> Repo.all()

    persisted_movements ++ synthetic_credit_expiry_movements(start.starts_on, date, after_date)
  end

  defp synthetic_credit_expiry_movements(starts_on, date, after_date) do
    lots =
      CreditLot
      |> where([lot], lot.remaining_cents > 0)
      |> where([lot], lot.expires_on <= ^date)
      |> Repo.all()

    issue_postings =
      lots
      |> Enum.map(& &1.source_operation_id)
      |> credit_issue_postings_by_operation()

    lower_bound = after_date || starts_on

    lots
    |> Enum.map(fn lot ->
      issue_posting = Map.get(issue_postings, lot.source_operation_id)
      posting_date = synthetic_credit_expiry_posting_date(lot, issue_posting)
      late_adjustment = synthetic_credit_expiry_late_adjustment?(lot, issue_posting)

      %{
        posting_date: posting_date,
        expired_cents: lot.remaining_cents,
        late_adjustment: late_adjustment
      }
    end)
    |> Enum.filter(fn movement ->
      movement_in_reporting_window?(movement, lower_bound, date, after_date)
    end)
    |> Enum.map(fn movement ->
      movement
      |> Map.merge(zero_credit_movements())
      |> Map.put(:posting_date, movement.posting_date)
      |> Map.put(:expired_cents, movement.expired_cents)
      |> Map.put(:late_adjustment, movement.late_adjustment)
    end)
  end

  defp credit_issue_postings_by_operation([]), do: %{}

  defp credit_issue_postings_by_operation(operation_ids) do
    operation_ids = Enum.reject(operation_ids, &is_nil/1)

    FinanceCreditMovement
    |> where([movement], movement.operation_id in ^operation_ids)
    |> where([movement], movement.issued_cents != 0)
    |> select([movement], {
      movement.operation_id,
      movement.posting_date,
      movement.late_adjustment
    })
    |> Repo.all()
    |> Map.new(fn {operation_id, posting_date, late_adjustment} ->
      {operation_id, %{posting_date: posting_date, late_adjustment: late_adjustment}}
    end)
  end

  defp synthetic_credit_expiry_posting_date(lot, nil), do: lot.expires_on

  defp synthetic_credit_expiry_posting_date(lot, issue_posting) do
    later_date(lot.expires_on, issue_posting.posting_date)
  end

  defp synthetic_credit_expiry_late_adjustment?(_lot, nil), do: false

  defp synthetic_credit_expiry_late_adjustment?(lot, issue_posting) do
    issue_posting.late_adjustment and
      Date.compare(issue_posting.posting_date, lot.expires_on) == :gt
  end

  defp record_cash_movement(operation, property_id, attrs)
       when is_binary(property_id) and is_map(attrs) do
    with {:ok, posting_date, late_adjustment?} <- finance_posting_date(operation) do
      movements = Map.merge(zero_cash_movements(), attrs)

      unless cash_movements_zero?(movements) do
        attrs =
          movements
          |> Map.merge(%{
            operation_id: operation_id(operation),
            posting_date: posting_date,
            property_id: property_id,
            late_adjustment: late_adjustment?
          })

        Repo.insert!(struct(FinanceCashMovement, attrs))
      end
    end

    :ok
  end

  defp record_cash_movement(_operation, _property_id, _attrs), do: :ok

  defp record_cash_movements_by_group(operation, movements, field) do
    movements
    |> Enum.reduce(%{}, fn movement, totals ->
      Map.update(
        totals,
        movement.reservation_id,
        Map.put(zero_cash_movements(), field, movement.amount_cents),
        fn existing ->
          merge_cash_movements(existing, %{field => movement.amount_cents})
        end
      )
    end)
    |> record_cash_movement_maps_by_group(operation)
  end

  defp record_chargeback_cash_movements(operation, movements) do
    movements
    |> Enum.reduce(%{}, fn movement, totals ->
      cash_movement =
        movement.disposition
        |> chargeback_cash_movement(movement.amount_cents)
        |> Map.merge(%{charged_back_cents: movement.amount_cents})

      Map.update(totals, movement.reservation_id, cash_movement, fn existing ->
        merge_cash_movements(existing, cash_movement)
      end)
    end)
    |> record_cash_movement_maps_by_group(operation)
  end

  defp chargeback_cash_movement(@held, _amount_cents), do: %{}
  defp chargeback_cash_movement(@refunded, amount_cents), do: %{refunded_cents: -amount_cents}
  defp chargeback_cash_movement(@retained, amount_cents), do: %{retained_cents: -amount_cents}

  defp chargeback_cash_movement(@converted_to_credit, amount_cents),
    do: %{converted_to_credit_cents: -amount_cents}

  defp record_cash_movement_maps_by_group(movements_by_group, operation) do
    group_properties =
      movements_by_group
      |> Map.keys()
      |> group_properties_by_id()

    Enum.each(movements_by_group, fn {group_id, movements} ->
      operation
      |> record_cash_movement(Map.fetch!(group_properties, group_id), movements)
    end)
  end

  defp record_transfer_cash_movements(
         operation,
         source_property_id,
         destination_property_id,
         chunks
       ) do
    cash_cents =
      chunks
      |> Enum.filter(&(&1.kind == :cash))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    cond do
      cash_cents == 0 ->
        :ok

      source_property_id == destination_property_id ->
        record_cash_movement(operation, source_property_id, %{
          transferred_out_cents: cash_cents,
          transferred_in_cents: cash_cents
        })

      true ->
        record_cash_movement(operation, source_property_id, %{transferred_out_cents: cash_cents})

        record_cash_movement(operation, destination_property_id, %{
          transferred_in_cents: cash_cents
        })
    end
  end

  defp record_credit_movement(operation, attrs) when is_map(attrs) do
    with {:ok, posting_date, late_adjustment?} <- finance_posting_date(operation) do
      movements = Map.merge(zero_credit_movements(), attrs)

      unless credit_movements_zero?(movements) do
        attrs =
          movements
          |> Map.merge(%{
            operation_id: operation_id(operation),
            posting_date: posting_date,
            late_adjustment: late_adjustment?
          })

        Repo.insert!(struct(FinanceCreditMovement, attrs))
      end
    end

    :ok
  end

  defp record_credit_movement(_operation, _attrs), do: :ok

  defp finance_posting_date(operation) do
    with {:ok, start} <- get_finance_reporting_start(),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation") do
      ordinary_posting_date = later_date(occurred_on, start.starts_on)
      posting_date = later_date(ordinary_posting_date, first_open_finance_date())

      {:ok, posting_date, Date.compare(posting_date, ordinary_posting_date) != :eq}
    else
      _no_reporting_or_bad_date -> :skip
    end
  end

  defp first_open_finance_date do
    case latest_finance_period_close_end_on() do
      nil -> ~D[0001-01-01]
      latest_closed_on -> Date.add(latest_closed_on, 1)
    end
  end

  defp latest_finance_period_close_end_on do
    FinancePeriodClose
    |> select([close], max(close.period_end_on))
    |> Repo.one()
  end

  defp finance_movement_window(query, nil, date) do
    query
    |> where([movement], movement.posting_date <= ^date)
  end

  defp finance_movement_window(query, after_date, date) do
    query
    |> where([movement], movement.posting_date > ^after_date)
    |> where([movement], movement.posting_date <= ^date)
  end

  defp movement_in_reporting_window?(movement, lower_bound, date, nil) do
    Date.compare(movement.posting_date, date) != :gt and
      Date.compare(movement.posting_date, lower_bound) == :gt
  end

  defp movement_in_reporting_window?(movement, lower_bound, date, _after_date) do
    Date.compare(movement.posting_date, lower_bound) == :gt and
      Date.compare(movement.posting_date, date) != :gt
  end

  defp late_adjustment?(movement), do: Map.get(movement, :late_adjustment, false)

  defp group_properties_by_id([]), do: %{}

  defp group_properties_by_id(group_ids) do
    Group
    |> where([group], group.id in ^group_ids)
    |> select([group], {group.id, group.property_id})
    |> Repo.all()
    |> Map.new()
  end

  defp aggregate_cash_movements(movements) do
    Enum.reduce(movements, zero_cash_movements(), &merge_cash_movements/2)
  end

  defp merge_cash_movements(movement, totals) do
    Enum.reduce(@cash_movement_fields, totals, fn field, totals ->
      Map.update(
        totals,
        field,
        movement_cents(movement, field),
        &(&1 + movement_cents(movement, field))
      )
    end)
  end

  defp cash_balance_delta(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents - movements.converted_to_credit_cents -
      movements.reduced_cents - movements.charged_back_cents
  end

  defp zero_cash_movements do
    Map.new(@cash_movement_fields, &{&1, 0})
  end

  defp cash_movements_zero?(movements) do
    Enum.all?(@cash_movement_fields, &(movement_cents(movements, &1) == 0))
  end

  defp aggregate_credit_movements(movements) do
    Enum.reduce(movements, zero_credit_movements(), &merge_credit_movements/2)
  end

  defp merge_credit_movements(movement, totals) do
    Enum.reduce(@credit_movement_fields, totals, fn field, totals ->
      Map.update(
        totals,
        field,
        movement_cents(movement, field),
        &(&1 + movement_cents(movement, field))
      )
    end)
  end

  defp credit_balance_delta(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp zero_credit_movements do
    Map.new(@credit_movement_fields, &{&1, 0})
  end

  defp credit_movements_zero?(movements) do
    Enum.all?(@credit_movement_fields, &(movement_cents(movements, &1) == 0))
  end

  defp movement_cents(%{} = movement, field), do: Map.get(movement, field, 0)

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt do
      right
    else
      left
    end
  end

  defp dates_through(start_date, end_date) do
    0..Date.diff(end_date, start_date)
    |> Enum.map(&Date.add(start_date, &1))
  end

  defp available_credit_lots(guest_id, on) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp available_credit_liability_cents(on) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> select([lot], coalesce(sum(lot.remaining_cents), 0))
    |> Repo.one()
  end

  defp active_credit_allocation_total_cents do
    RoomCreditAllocation
    |> join(:inner, [allocation], group in Group, on: allocation.reservation_id == group.id)
    |> join(:inner, [allocation, _group], room in Room, on: allocation.room_id == room.id)
    |> where(
      [allocation, group, room],
      allocation.active == true and group.status == @active and room.status == @active
    )
    |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_shortfall_cents do
    CreditLot
    |> Repo.all()
    |> Enum.map(fn lot ->
      active_cents =
        RoomCreditAllocation
        |> join(:inner, [allocation], group in Group, on: allocation.reservation_id == group.id)
        |> join(:inner, [allocation, _group], room in Room, on: allocation.room_id == room.id)
        |> where([allocation, group, room], allocation.credit_lot_id == ^lot.id)
        |> where(
          [allocation, group, room],
          allocation.active == true and group.status == @active and room.status == @active
        )
        |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
        |> Repo.one()

      min(cents(lot.unrecovered_clawback_cents), active_cents)
    end)
    |> Enum.sum()
  end

  defp active_rooms(group) do
    Room
    |> where([room], room.reservation_id == ^group.id)
    |> where([room], room.status == ^@active)
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp destination_room_slots(group) do
    group
    |> active_rooms()
    |> Enum.map(fn room ->
      %{
        room: room,
        remaining_cents: max(room_deposit_due_cents(room) - room_paid_cents(room.id), 0)
      }
    end)
  end

  defp active_room_count(group_id) do
    Room
    |> where([room], room.reservation_id == ^group_id)
    |> where([room], room.status == ^@active)
    |> select([room], count(room.id))
    |> Repo.one()
  end

  defp room_funding_chunks(group, amount_cents) do
    {_remaining_cents, chunks} =
      group
      |> active_rooms()
      |> Enum.reduce_while({amount_cents, []}, fn room, {remaining_cents, chunks} ->
        if remaining_cents == 0 do
          {:halt, {0, chunks}}
        else
          available_cents = max(room_deposit_due_cents(room) - room_paid_cents(room.id), 0)
          chunk_cents = min(available_cents, remaining_cents)

          if chunk_cents > 0 do
            {:cont, {remaining_cents - chunk_cents, chunks ++ [{room, chunk_cents}]}}
          else
            {:cont, {remaining_cents, chunks}}
          end
        end
      end)

    chunks
  end

  defp room_paid_cents(room_id) do
    cash_paid_cents_for_room(room_id) + credit_paid_cents_for_room(room_id)
  end

  defp group_active_totals(group_id) do
    lodging_total_cents =
      Room
      |> where([room], room.reservation_id == ^group_id)
      |> where([room], room.status == ^@active)
      |> select([room], coalesce(sum(room.lodging_total_cents), 0))
      |> Repo.one()

    deposit_due_cents =
      Room
      |> where([room], room.reservation_id == ^group_id)
      |> where([room], room.status == ^@active)
      |> select([room], coalesce(sum(room.deposit_due_cents), 0))
      |> Repo.one()

    cash_paid_cents = cash_held_cents_for_group(group_id)
    credit_paid_cents = credit_paid_cents_for_group(group_id)
    deposit_paid_cents = cash_paid_cents + credit_paid_cents

    %{
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      deposit_paid_cents: deposit_paid_cents,
      outstanding_deposit_cents: max(deposit_due_cents - deposit_paid_cents, 0)
    }
  end

  defp group_cash_settlement_totals(group_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.reservation_id == ^group_id)
    |> where(
      [disposition],
      disposition.disposition in [@refunded, @retained, @converted_to_credit]
    )
    |> group_by([disposition], disposition.disposition)
    |> select(
      [disposition],
      {disposition.disposition, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cash_totals_by_room(group_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.reservation_id == ^group_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> group_by([disposition, _room], disposition.room_id)
    |> select(
      [disposition, _room],
      {disposition.room_id, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp credit_totals_by_room(group_id) do
    RoomCreditAllocation
    |> join(:inner, [allocation], room in Room, on: allocation.room_id == room.id)
    |> where([allocation, room], allocation.reservation_id == ^group_id)
    |> where([allocation, room], allocation.active == true and room.status == ^@active)
    |> group_by([allocation, _room], allocation.room_id)
    |> select(
      [allocation, _room],
      {allocation.room_id, coalesce(sum(allocation.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cash_held_cents_for_group(group_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.reservation_id == ^group_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> select([disposition, _room], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_paid_cents_for_group(group_id) do
    RoomCreditAllocation
    |> join(:inner, [allocation], room in Room, on: allocation.room_id == room.id)
    |> where([allocation, room], allocation.reservation_id == ^group_id)
    |> where([allocation, room], allocation.active == true and room.status == ^@active)
    |> select([allocation, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp held_funding_cents_for_group(group_id) do
    cash_held_cents_for_group(group_id) + credit_paid_cents_for_group(group_id)
  end

  defp cash_paid_cents_for_room(room_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.room_id == ^room_id)
    |> where([disposition], disposition.disposition == ^@held)
    |> select([disposition], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_paid_cents_for_room(room_id) do
    RoomCreditAllocation
    |> where([allocation], allocation.room_id == ^room_id)
    |> where([allocation], allocation.active == true)
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp cash_disposition_total(disposition) do
    CashPaymentDisposition
    |> where([cash_disposition], cash_disposition.disposition == ^disposition)
    |> select([cash_disposition], coalesce(sum(cash_disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp payment_disposition_totals(payment_operation_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.payment_operation_id == ^payment_operation_id)
    |> group_by([disposition], disposition.disposition)
    |> select(
      [disposition],
      {disposition.disposition, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp held_cash_by_group(payment_operation_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], group in Group, on: disposition.reservation_id == group.id)
    |> join(:inner, [disposition, _group], room in Room, on: disposition.room_id == room.id)
    |> where(
      [disposition, _group, room],
      disposition.payment_operation_id == ^payment_operation_id
    )
    |> where(
      [disposition, group, room],
      disposition.disposition == ^@held and group.status == ^@active and room.status == ^@active
    )
    |> group_by([_disposition, group, _room], group.group_id)
    |> order_by([_disposition, group, _room], asc: group.group_id)
    |> select([disposition, group, _room], %{
      group_id: group.group_id,
      amount_cents: coalesce(sum(disposition.amount_cents), 0)
    })
    |> Repo.all()
  end

  defp cash_payment_transferred?(payment_operation_id) do
    CashPaymentTransfer
    |> where([transfer], transfer.payment_operation_id == ^payment_operation_id)
    |> Repo.exists?()
  end

  defp payment_held_cash_cents(payment_operation_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.payment_operation_id == ^payment_operation_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> select([disposition, _room], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp held_cash_rows_for_payment(payment_operation_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.payment_operation_id == ^payment_operation_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> order_by([disposition, _room], desc: disposition.sequence, desc: disposition.id)
    |> select([disposition, _room], disposition)
    |> Repo.all()
  end

  defp held_funding_rows_for_group(group_id) do
    cash_rows =
      CashPaymentDisposition
      |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
      |> where([disposition, room], disposition.reservation_id == ^group_id)
      |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
      |> select([disposition, _room], disposition)
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          kind: :cash,
          id: row.id,
          row: row,
          amount_cents: row.amount_cents,
          sequence: row.sequence,
          payment_operation_id: row.payment_operation_id
        }
      end)

    credit_rows =
      RoomCreditAllocation
      |> join(:inner, [allocation], room in Room, on: allocation.room_id == room.id)
      |> where([allocation, room], allocation.reservation_id == ^group_id)
      |> where([allocation, room], allocation.active == true and room.status == ^@active)
      |> select([allocation, _room], allocation)
      |> Repo.all()
      |> Enum.map(fn row ->
        %{
          kind: :credit,
          id: row.id,
          row: row,
          amount_cents: row.amount_cents,
          sequence: row.sequence,
          credit_lot_id: row.credit_lot_id,
          source_operation_id: row.source_operation_id
        }
      end)

    Enum.sort_by(cash_rows ++ credit_rows, &{&1.sequence, &1.id}, :desc)
  end

  defp held_cash_rows_for_rooms(room_ids) do
    CashPaymentDisposition
    |> where([disposition], disposition.room_id in ^room_ids)
    |> where([disposition], disposition.disposition == ^@held)
    |> order_by([disposition], asc: disposition.sequence, asc: disposition.id)
    |> Repo.all()
  end

  defp active_credit_allocations_for_rooms(room_ids) do
    RoomCreditAllocation
    |> where([allocation], allocation.room_id in ^room_ids)
    |> where([allocation], allocation.active == true)
    |> order_by([allocation], asc: allocation.sequence, asc: allocation.id)
    |> Repo.all()
  end

  defp chargeable_payment_cents(dispositions) do
    Enum.sum([
      Map.get(dispositions, @held, 0),
      Map.get(dispositions, @refunded, 0),
      Map.get(dispositions, @retained, 0),
      Map.get(dispositions, @converted_to_credit, 0)
    ])
  end

  defp next_funding_sequence do
    cash_sequence =
      CashPaymentDisposition
      |> select([disposition], max(disposition.sequence))
      |> Repo.one()
      |> cents()

    credit_sequence =
      RoomCreditAllocation
      |> select([allocation], max(allocation.sequence))
      |> Repo.one()
      |> cents()

    max(cash_sequence, credit_sequence) + 1
  end

  defp room_status(%Room{status: nil}), do: @active
  defp room_status(%Room{status: status}), do: status

  defp room_lodging_total_cents(%Room{lodging_total_cents: nil}), do: 0
  defp room_lodging_total_cents(%Room{lodging_total_cents: cents}), do: cents(cents)

  defp room_deposit_due_cents(%Room{deposit_due_cents: nil}), do: 0
  defp room_deposit_due_cents(%Room{deposit_due_cents: cents}), do: cents(cents)

  defp sum_groups(field, filters \\ []) do
    Group
    |> where(^filters)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp cents(nil), do: 0
  defp cents(value), do: value

  defp fetch_string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:reject, rejected(map, "invalid_operation")}
    end
  end

  defp fetch_positive_integer(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:reject, rejected(map, code)}
    end
  end

  defp fetch_date(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:reject, rejected(map, code)}
        end

      _other ->
        {:reject, rejected(map, code)}
    end
  end

  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method", @cash) do
      refund_method when refund_method in [@cash, @hotel_credit] ->
        {:ok, refund_method}

      _other ->
        {:reject, rejected(operation, "invalid_operation")}
    end
  end

  defp reporting_date(nil), do: {:ok, Date.utc_today()}

  defp reporting_date(on) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_on}
    end
  end

  defp reporting_date(_on), do: {:error, :invalid_on}

  defp finance_report_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed_date} -> {:ok, parsed_date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp finance_report_date(_date), do: {:error, :invalid_reporting_date}

  defp fetch_operation_id(operation), do: fetch_string(operation, "operation_id")

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp applied_cash_payment_result(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: result
       })
       when is_map(result) do
    if map_get(result, "status") == "applied" and is_integer(map_get(result, "amount_cents")) do
      {:ok, result}
    else
      :error
    end
  end

  defp applied_cash_payment_result(_record), do: :error

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(map, atom_key)
    end
  end

  defp report_value(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(map, atom_key, default)
    end
  end

  defp rejected(operation, code) do
    %{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    }
  end

  defp rejected_with_group(operation, code, group_id) do
    operation
    |> rejected(code)
    |> Map.put(:group_id, group_id)
  end

  defp canonical_json(%{} = map) do
    encoded_pairs =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
      end)

    "{" <> Enum.join(encoded_pairs, ",") <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value) do
    Jason.encode!(value)
  end
end
