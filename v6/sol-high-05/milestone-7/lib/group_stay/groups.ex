defmodule GroupStay.Groups do
  @moduledoc """
  Applies partner operations and exposes the resulting group-deposit records.

  Every operation runs in its own immediate transaction. This commits its domain
  changes and durable idempotency record atomically, and serializes writes so
  revision checks observe the latest committed group state.
  """

  import Ecto.Query

  alias GroupStay.Groups.{
    CreditExpirySchedule,
    CreditEntitlement,
    CreditLot,
    FinanceMovement,
    FinanceOpeningCash,
    FinancePeriodClose,
    FinanceReporting,
    Group,
    Operation,
    PaymentDisposition,
    PaymentSettlement,
    RoomFunding
  }

  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, restore_result_keys(operation.result)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        case Repo.get(PaymentDisposition, payment_operation_id) do
          %PaymentDisposition{} = payment ->
            if applied_cash_payment?(operation),
              do: {:ok, serialize_payment(payment)},
              else: {:error, :payment_not_reconcilable}

          _ ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  def ledger do
    {:ok, ledger} = ledger(Date.utc_today())
    ledger
  end

  def ledger(on) do
    with {:ok, on} <- normalize_date(on) do
      cash_totals =
        from(group in Group,
          select: %{
            cash_held_cents: coalesce(sum(group.cash_paid_cents), 0),
            cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
            cash_converted_to_credit_cents:
              coalesce(sum(group.cash_converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(group.cash_reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(group.cash_charged_back_cents), 0)
          }
        )
        |> Repo.one!()

      {:ok,
       cash_totals
       |> Map.put(:credit_liability_cents, credit_liability(on))
       |> Map.put(:credit_shortfall_cents, credit_shortfall())}
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    with {:ok, on} <- normalize_date(on) do
      lots = available_lots(guest_id, on)

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: Enum.sum_by(lots, & &1.remaining_cents),
         lots: Enum.map(lots, &serialize_lot/1)
       }}
    end
  end

  def daily_finance_report(date) do
    with {:ok, date} <- normalize_reporting_date(date),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         :ok <- report_available(reporting, date) do
      {:ok, build_daily_finance_report(reporting, date)}
    else
      {:error, :invalid_reporting_date} -> {:error, :invalid_reporting_date}
      nil -> {:error, :report_not_available}
      {:error, :report_not_available} -> {:error, :report_not_available}
    end
  end

  defp process_operation(operation) do
    {:ok, result} =
      Repo.transaction(fn -> process_operation_once(operation) end, mode: :immediate)

    result
  end

  defp process_operation_once(operation) when is_map(operation) do
    case operation_id_for_idempotency(operation) do
      {:ok, operation_id} ->
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil -> apply_and_remember(operation)
          remembered -> replay_or_reject_conflict(operation, remembered)
        end

      :error ->
        apply_operation(operation)
    end
  end

  defp process_operation_once(operation), do: apply_operation(operation)

  defp apply_and_remember(operation) do
    result = apply_operation(operation)

    %Operation{}
    |> Operation.changeset(%{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_content: operation,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp replay_or_reject_conflict(operation, remembered) do
    if remembered.submitted_content === operation do
      restore_result_keys(remembered.result)
    else
      reject(operation, "operation_id_conflict")
    end
  end

  defp restore_result_keys(result) do
    Map.new(result, fn {key, value} -> {restore_result_key(key), value} end)
  end

  defp restore_result_key(key) when is_atom(key), do: key
  defp restore_result_key(key), do: String.to_existing_atom(key)

  defp operation_id_for_idempotency(%{"operation_id" => operation_id})
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, operation_id}

  defp operation_id_for_idempotency(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: update_group(operation, &record_cash_payment/2)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: update_group(operation, &reschedule_group/2)

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: update_group(operation, &cancel_group/2)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: update_group(operation, &apply_hotel_credit/2)

  defp apply_operation(%{"type" => "cancel_rooms"} = operation),
    do: update_group(operation, &cancel_rooms/2)

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp apply_operation(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp apply_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp apply_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp apply_operation(%{"type" => "close_finance_period"} = operation),
    do: close_finance_period(operation)

  defp apply_operation(operation), do: reject(operation, "invalid_operation")

  defp start_finance_reporting(operation) do
    with :ok <- require_fields(operation, ["operation_id"]),
         true <- usable_id?(operation["operation_id"]) do
      start_finance_reporting_with_id(operation)
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp start_finance_reporting_with_id(operation) do
    with :ok <- require_fields(operation, ["starts_on"]),
         {:ok, starts_on} <- parse_date(operation["starts_on"]),
         nil <- Repo.get(FinanceReporting, 1) do
      opening_credit = credit_liability(starts_on)

      %FinanceReporting{}
      |> FinanceReporting.changeset(%{
        id: 1,
        starts_on: starts_on,
        opening_credit_liability_cents: opening_credit
      })
      |> Repo.insert!()

      initialize_opening_cash()
      initialize_credit_expiry_schedules(starts_on)

      applied(operation, starts_on: Date.to_iso8601(starts_on))
    else
      {:error, :missing_data} -> reject(operation, "invalid_reporting_date")
      {:error, :invalid_date} -> reject(operation, "invalid_reporting_date")
      %FinanceReporting{} -> reject(operation, "reporting_already_started")
    end
  end

  defp close_finance_period(operation) do
    with :ok <- require_fields(operation, ["operation_id"]),
         true <- usable_id?(operation["operation_id"]) do
      close_finance_period_with_id(operation)
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp close_finance_period_with_id(operation) do
    with :ok <- require_fields(operation, ["period_end_on"]),
         {:ok, period_end_on} <- parse_date(operation["period_end_on"]),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         :ok <- valid_period_close(reporting, period_end_on) do
      %FinancePeriodClose{}
      |> FinancePeriodClose.changeset(%{
        period_end_on: period_end_on,
        operation_id: operation["operation_id"]
      })
      |> Repo.insert!()

      applied(operation, period_end_on: Date.to_iso8601(period_end_on))
    else
      _ -> reject(operation, "invalid_period")
    end
  end

  defp valid_period_close(reporting, period_end_on) do
    latest_close = latest_period_end_on()

    if Date.compare(period_end_on, reporting.starts_on) in [:eq, :gt] and
         (is_nil(latest_close) or Date.compare(period_end_on, latest_close) == :gt) do
      :ok
    else
      {:error, :invalid_period}
    end
  end

  defp open_group(operation) do
    with :ok <- require_open_fields(operation),
         nil <- Repo.get(Group, operation["group_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      rooms = detailed_rooms(rooms, nights, operation["rate_plan"])
      lodging_total = Enum.sum_by(rooms, & &1["lodging_total_cents"])
      deposit_due = Enum.sum_by(rooms, & &1["deposit_due_cents"])

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        status: "active",
        rooms: %{"items" => rooms},
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0,
        revision: 1
      }

      case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
        {:ok, _group} ->
          applied(operation,
            group_id: operation["group_id"],
            deposit_due_cents: deposit_due,
            revision: 1
          )

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            reject(operation, "group_already_exists")
          else
            reject(operation, "invalid_operation")
          end
      end
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      %Group{} -> reject(operation, "group_already_exists")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> reject(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
    end
  end

  defp update_group(operation, callback) do
    with :ok <- require_update_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]),
         :ok <- check_revision(operation, group) do
      callback.(operation, group)
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> stale_revision(operation, group)
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "amount_cents"]),
         :ok <- active(group),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         outstanding = outstanding_deposit(group),
         :ok <- not_excessive(operation["amount_cents"], outstanding) do
      allocate_cash_to_rooms(group, operation["operation_id"], operation["amount_cents"])

      {:ok, _payment} =
        %PaymentDisposition{}
        |> PaymentDisposition.changeset(%{
          payment_operation_id: operation["operation_id"],
          original_group_id: group.group_id,
          recorded_cents: operation["amount_cents"],
          held_cents: operation["amount_cents"],
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0,
          transfer_participated: false
        })
        |> Repo.insert()

      paid = group.deposit_paid_cents + operation["amount_cents"]
      cash_paid = group.cash_paid_cents + operation["amount_cents"]
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{deposit_paid_cents: paid, cash_paid_cents: cash_paid, revision: revision})

      record_cash_movements(operation, [
        {group.property_id, "received", operation["amount_cents"]}
      ])

      applied(operation,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: group.deposit_due_cents - paid,
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_amount} ->
        reject(operation, "invalid_amount")

      {:error, :payment_exceeds_outstanding} ->
        reject(operation, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "new_arrival_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- future_arrival(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        policy_version: effective_policy_version(group),
        refundable_until: refundable_until(group, new_arrival_on),
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_stay")

      {:error, :invalid_stay} ->
        reject(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- refund_method(operation),
         refundable = refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable) do
      room_ids = active_rooms(group) |> Enum.map(& &1["room_id"])

      {:ok, settled} =
        settle_rooms(group, room_ids, operation, occurred_on, refundable, refund_method)

      applied(operation,
        group_id: group.group_id,
        refunded_cents: settled.refunded_cents,
        retained_cents: settled.retained_cents,
        credit_issued_cents: settled.credit_issued_cents,
        revision: settled.revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_refund_method} ->
        reject(operation, "invalid_operation")

      {:error, :refund_method_not_available} ->
        reject(operation, "refund_method_not_available")
    end
  end

  defp cancel_rooms(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "room_ids"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, room_ids} <- validate_cancelled_rooms(group, operation["room_ids"]),
         {:ok, refund_method} <- refund_method(operation),
         refundable = refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable),
         {:ok, settled} <-
           settle_rooms(group, room_ids, operation, occurred_on, refundable, refund_method) do
      applied(operation,
        group_id: group.group_id,
        cancelled_room_ids: room_ids,
        refunded_cents: settled.refunded_cents,
        retained_cents: settled.retained_cents,
        credit_issued_cents: settled.credit_issued_cents,
        revision: settled.revision
      )
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
      {:error, :invalid_refund_method} -> reject(operation, "invalid_operation")
      {:error, :refund_method_not_available} -> reject(operation, "refund_method_not_available")
    end
  end

  defp apply_hotel_credit(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "amount_cents"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- not_excessive(operation["amount_cents"], outstanding_deposit(group)),
         {:ok, lots} <- enough_credit(group.guest_id, operation["amount_cents"], occurred_on) do
      restored_expired =
        consume_credit_expiry_schedules(operation, lots, operation["amount_cents"])

      allocate_credit_to_rooms(lots, group, operation["amount_cents"])

      paid = group.deposit_paid_cents + operation["amount_cents"]
      credit_paid = group.credit_paid_cents + operation["amount_cents"]
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          deposit_paid_cents: paid,
          credit_paid_cents: credit_paid,
          revision: revision
        })

      record_credit_movements(operation, [{"expired", -restored_expired}])

      applied(operation,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: group.deposit_due_cents - paid,
        revision: revision
      )
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_exceeds_outstanding} -> reject(operation, "payment_exceeds_outstanding")
      {:error, :insufficient_credit} -> reject(operation, "insufficient_credit")
    end
  end

  defp transfer_deposit(operation) do
    with :ok <- require_transfer_fields(operation),
         %Group{} = source <- Repo.get(Group, operation["source_group_id"]),
         %Group{} = destination <- Repo.get(Group, operation["destination_group_id"]),
         :ok <- check_revision(operation, source),
         :ok <- check_destination_revision(operation, destination),
         :ok <- valid_transfer_pair(source, destination),
         :ok <- active_transfer_group(source),
         :ok <- active_transfer_group(destination),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- enough_held_funding(source, operation["amount_cents"]),
         :ok <- enough_transfer_capacity(destination, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      sources = draw_transfer_sources(source, amount)
      allocate_sources_to_rooms(destination, sources)
      mark_transferred_payments(sources)

      cash =
        sources
        |> Enum.filter(&(&1.funding_type == "cash"))
        |> Enum.sum_by(& &1.amount_cents)

      credit = amount - cash
      source_revision = source.revision + 1
      destination_revision = destination.revision + 1

      {:ok, updated_source} =
        persist(source, %{
          deposit_paid_cents: source.deposit_paid_cents - amount,
          cash_paid_cents: source.cash_paid_cents - cash,
          credit_paid_cents: source.credit_paid_cents - credit,
          revision: source_revision
        })

      {:ok, updated_destination} =
        persist(destination, %{
          deposit_paid_cents: destination.deposit_paid_cents + amount,
          cash_paid_cents: destination.cash_paid_cents + cash,
          credit_paid_cents: destination.credit_paid_cents + credit,
          revision: destination_revision
        })

      record_cash_movements(operation, [
        {source.property_id, "transferred_out", cash},
        {destination.property_id, "transferred_in", cash}
      ])

      applied(operation,
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: amount,
        source_outstanding_deposit_cents: outstanding_deposit(updated_source),
        destination_outstanding_deposit_cents: outstanding_deposit(updated_destination),
        source_revision: source_revision,
        destination_revision: destination_revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      nil ->
        missing_transfer_group(operation)

      {:error, :stale_revision, group} ->
        stale_revision(operation, group)

      {:error, :stale_destination_revision, group} ->
        stale_destination_revision(operation, group)

      {:error, :invalid_transfer} ->
        reject(operation, "invalid_transfer")

      {:error, :group_not_active, group} ->
        reject(operation, "group_not_active", group_id: group.group_id)

      {:error, :invalid_amount} ->
        reject(operation, "invalid_amount")

      {:error, :transfer_exceeds_held_funding} ->
        reject(operation, "transfer_exceeds_held_funding")

      {:error, :transfer_exceeds_outstanding} ->
        reject(operation, "transfer_exceeds_outstanding")
    end
  end

  defp reduce_cash_payment(operation) do
    with :ok <- require_payment_adjustment_fields(operation, ["amount_cents"]),
         %Operation{} = target <-
           Repo.get_by(Operation, operation_id: operation["payment_operation_id"]),
         true <- applied_cash_payment?(target),
         %PaymentDisposition{} = payment <-
           Repo.get(PaymentDisposition, operation["payment_operation_id"]),
         %Group{} = group <- Repo.get(Group, payment.original_group_id),
         :ok <- check_revision(operation, group),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- reducible(payment),
         :ok <- reduction_not_excessive(operation["amount_cents"], payment.held_cents) do
      amount = operation["amount_cents"]
      removed_by_group = remove_cash_funding(payment.payment_operation_id, amount)

      {:ok, _payment} =
        persist_payment(payment, %{
          held_cents: payment.held_cents - amount,
          reduced_cents: payment.reduced_cents + amount
        })

      updated_groups = update_groups_for_reduction(group, removed_by_group, amount)
      updated_group = Map.fetch!(updated_groups, group.group_id)

      record_group_cash_movements(operation, removed_by_group, "reduced")

      applied(operation,
        payment_operation_id: payment.payment_operation_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(updated_group),
        revision: updated_group.revision
      )
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      nil -> reject(operation, "operation_not_found")
      false -> reject(operation, "payment_not_reducible")
      {:error, :stale_revision, group} -> stale_revision(operation, group)
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_not_reducible} -> reject(operation, "payment_not_reducible")
      {:error, :reduction_exceeds_held_cash} -> reject(operation, "reduction_exceeds_held_cash")
    end
  end

  defp charge_back_payment(operation) do
    with :ok <- require_payment_adjustment_fields(operation, []),
         %Operation{} = target <-
           Repo.get_by(Operation, operation_id: operation["payment_operation_id"]),
         true <- applied_cash_payment?(target),
         %PaymentDisposition{} = payment <-
           Repo.get(PaymentDisposition, operation["payment_operation_id"]),
         %Group{} = group <- Repo.get(Group, payment.original_group_id),
         :ok <- check_revision(operation, group),
         :ok <- chargeable(payment) do
      charged_back =
        payment.held_cents + payment.refunded_cents + payment.retained_cents +
          payment.converted_to_credit_cents

      removed_by_group = remove_cash_funding(payment.payment_operation_id, payment.held_cents)
      settlements_by_group = payment_settlements_by_group(payment.payment_operation_id)

      assert_chargeback_attribution!(charged_back, removed_by_group, settlements_by_group)

      revoked =
        revoke_credit_entitlements(payment.payment_operation_id, operation_posting_on(operation))

      {:ok, _payment} =
        persist_payment(payment, %{
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: payment.charged_back_cents + charged_back
        })

      updated_groups = update_groups_for_chargeback(group, removed_by_group, settlements_by_group)
      updated_group = Map.fetch!(updated_groups, group.group_id)
      delete_payment_settlements(payment.payment_operation_id)

      record_chargeback_cash_movements(operation, removed_by_group, settlements_by_group)
      record_credit_movements(operation, [{"revoked", revoked}])

      applied(operation,
        payment_operation_id: payment.payment_operation_id,
        group_id: group.group_id,
        charged_back_cents: charged_back,
        outstanding_deposit_cents: outstanding_deposit(updated_group),
        revision: updated_group.revision
      )
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      nil -> reject(operation, "operation_not_found")
      false -> reject(operation, "payment_not_chargeable")
      {:error, :stale_revision, group} -> stale_revision(operation, group)
      {:error, :payment_not_chargeable} -> reject(operation, "payment_not_chargeable")
    end
  end

  defp require_payment_adjustment_fields(operation, extra) do
    with :ok <- require_fields(operation, ["operation_id", "payment_operation_id" | extra]),
         true <- usable_id?(operation["operation_id"]),
         true <- usable_id?(operation["payment_operation_id"]) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp applied_cash_payment?(%Operation{operation_type: "record_cash_payment", result: result}),
    do: result["status"] == "applied"

  defp applied_cash_payment?(_operation), do: false

  defp reducible(%PaymentDisposition{held_cents: held}) when held > 0, do: :ok
  defp reducible(_payment), do: {:error, :payment_not_reducible}

  defp reduction_not_excessive(amount, held) when amount <= held, do: :ok

  defp reduction_not_excessive(_amount, _held),
    do: {:error, :reduction_exceeds_held_cash}

  defp chargeable(%PaymentDisposition{charged_back_cents: 0} = payment) do
    remaining = payment.recorded_cents - payment.reduced_cents
    if remaining > 0, do: :ok, else: {:error, :payment_not_chargeable}
  end

  defp chargeable(_payment), do: {:error, :payment_not_chargeable}

  defp persist(group, attrs) do
    group
    |> Group.changeset(Map.merge(Map.from_struct(group), attrs))
    |> Repo.update()
  end

  defp persist_payment(payment, attrs) do
    payment
    |> PaymentDisposition.changeset(Map.merge(Map.from_struct(payment), attrs))
    |> Repo.update()
  end

  defp require_transfer_fields(operation) do
    required = [
      "operation_id",
      "source_group_id",
      "destination_group_id",
      "amount_cents"
    ]

    with :ok <- require_fields(operation, required),
         true <- usable_id?(operation["operation_id"]),
         true <- usable_id?(operation["source_group_id"]),
         true <- usable_id?(operation["destination_group_id"]) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp missing_transfer_group(operation) do
    group_id =
      if Repo.get(Group, operation["source_group_id"]),
        do: operation["destination_group_id"],
        else: operation["source_group_id"]

    reject(operation, "group_not_found", group_id: group_id)
  end

  defp check_destination_revision(operation, group) do
    if Map.has_key?(operation, "destination_expected_revision") and
         operation["destination_expected_revision"] != group.revision do
      {:error, :stale_destination_revision, group}
    else
      :ok
    end
  end

  defp stale_destination_revision(operation, group) do
    reject(operation, "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["destination_expected_revision"],
      actual_revision: group.revision
    )
  end

  defp valid_transfer_pair(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, :invalid_transfer}
  end

  defp active_transfer_group(%Group{status: "active"}), do: :ok
  defp active_transfer_group(group), do: {:error, :group_not_active, group}

  defp enough_held_funding(group, amount) do
    held =
      from(funding in RoomFunding,
        where: funding.group_id == ^group.group_id,
        select: coalesce(sum(funding.amount_cents), 0)
      )
      |> Repo.one!()

    if held >= amount,
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding}
  end

  defp enough_transfer_capacity(group, amount) do
    if outstanding_deposit(group) >= amount,
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding}
  end

  defp draw_transfer_sources(group, amount) do
    fundings =
      from(funding in RoomFunding,
        where: funding.group_id == ^group.group_id,
        order_by: [desc: funding.id]
      )
      |> Repo.all()

    {sources, left} =
      Enum.reduce_while(fundings, {[], amount}, fn funding, {sources, left} ->
        used = min(funding.amount_cents, left)

        if used == funding.amount_cents do
          Repo.delete!(funding)
        else
          funding
          |> RoomFunding.changeset(%{amount_cents: funding.amount_cents - used})
          |> Repo.update!()
        end

        source = %{
          funding_type: funding.funding_type,
          payment_operation_id: funding.payment_operation_id,
          credit_lot_id: funding.credit_lot_id,
          amount_cents: used
        }

        if used == left,
          do: {:halt, {sources ++ [source], 0}},
          else: {:cont, {sources ++ [source], left - used}}
      end)

    if left == 0, do: sources, else: raise("room funding allocation is inconsistent")
  end

  defp mark_transferred_payments(sources) do
    sources
    |> Enum.filter(&(&1.funding_type == "cash" and not is_nil(&1.payment_operation_id)))
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      payment = Repo.get!(PaymentDisposition, payment_operation_id)

      if not payment.transfer_participated do
        {:ok, _payment} = persist_payment(payment, %{transfer_participated: true})
      end
    end)
  end

  defp remove_cash_funding(_payment_operation_id, 0), do: %{}

  defp remove_cash_funding(payment_operation_id, amount) do
    fundings =
      from(funding in RoomFunding,
        where:
          funding.payment_operation_id == ^payment_operation_id and
            funding.funding_type == "cash",
        order_by: [desc: funding.id]
      )
      |> Repo.all()

    {left, removed_by_group} =
      Enum.reduce_while(fundings, {amount, %{}}, fn funding, {left, removed} ->
        used = min(funding.amount_cents, left)

        cond do
          funding.amount_cents <= left ->
            Repo.delete!(funding)

            removed = Map.update(removed, funding.group_id, used, &(&1 + used))

            if funding.amount_cents == left,
              do: {:halt, {0, removed}},
              else: {:cont, {left - funding.amount_cents, removed}}

          true ->
            funding
            |> RoomFunding.changeset(%{amount_cents: funding.amount_cents - left})
            |> Repo.update!()

            removed = Map.update(removed, funding.group_id, used, &(&1 + used))
            {:halt, {0, removed}}
        end
      end)

    if left == 0,
      do: removed_by_group,
      else: raise("cash funding allocation is inconsistent")
  end

  defp update_groups_for_reduction(original_group, removed_by_group, amount) do
    affected_group_ids =
      removed_by_group
      |> Map.keys()
      |> Enum.concat([original_group.group_id])
      |> Enum.uniq()

    Map.new(affected_group_ids, fn group_id ->
      group = Repo.get!(Group, group_id)
      removed = Map.get(removed_by_group, group_id, 0)
      reduced = if group_id == original_group.group_id, do: amount, else: 0

      {:ok, updated_group} =
        persist(group, %{
          deposit_paid_cents: group.deposit_paid_cents - removed,
          cash_paid_cents: group.cash_paid_cents - removed,
          cash_reduced_cents: group.cash_reduced_cents + reduced,
          revision: group.revision + 1
        })

      {group_id, updated_group}
    end)
  end

  defp payment_settlements_by_group(payment_operation_id) do
    from(settlement in PaymentSettlement,
      where: settlement.payment_operation_id == ^payment_operation_id,
      group_by: [settlement.group_id, settlement.disposition],
      select: {{settlement.group_id, settlement.disposition}, sum(settlement.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {{group_id, disposition}, amount}, groups ->
      Map.update(groups, group_id, %{disposition => amount}, &Map.put(&1, disposition, amount))
    end)
  end

  defp assert_chargeback_attribution!(charged_back, removed_by_group, settlements_by_group) do
    attributed =
      Enum.sum(Map.values(removed_by_group)) +
        Enum.sum_by(settlements_by_group, fn {_group_id, dispositions} ->
          dispositions |> Map.values() |> Enum.sum()
        end)

    if attributed != charged_back do
      raise "payment disposition attribution is inconsistent"
    end
  end

  defp update_groups_for_chargeback(original_group, removed_by_group, settlements_by_group) do
    affected_group_ids =
      removed_by_group
      |> Map.keys()
      |> Enum.concat(Map.keys(settlements_by_group))
      |> Enum.concat([original_group.group_id])
      |> Enum.uniq()

    Map.new(affected_group_ids, fn group_id ->
      group = Repo.get!(Group, group_id)
      removed = Map.get(removed_by_group, group_id, 0)
      settlements = Map.get(settlements_by_group, group_id, %{})
      refunded = Map.get(settlements, "refunded", 0)
      retained = Map.get(settlements, "retained", 0)
      converted = Map.get(settlements, "converted_to_credit", 0)
      charged_back = removed + refunded + retained + converted

      {:ok, updated_group} =
        persist(group, %{
          deposit_paid_cents: group.deposit_paid_cents - removed,
          cash_paid_cents: group.cash_paid_cents - removed,
          cash_refunded_cents: group.cash_refunded_cents - refunded,
          cash_retained_cents: group.cash_retained_cents - retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents - converted,
          cash_charged_back_cents: group.cash_charged_back_cents + charged_back,
          revision: group.revision + 1
        })

      {group_id, updated_group}
    end)
  end

  defp delete_payment_settlements(payment_operation_id) do
    from(settlement in PaymentSettlement,
      where: settlement.payment_operation_id == ^payment_operation_id
    )
    |> Repo.delete_all()
  end

  defp revoke_credit_entitlements(payment_operation_id, posting_on) do
    entitlements =
      from(entitlement in CreditEntitlement,
        where:
          entitlement.payment_operation_id == ^payment_operation_id and
            entitlement.charged_back == false,
        order_by: [asc: entitlement.id]
      )
      |> Repo.all()

    Enum.reduce(entitlements, 0, fn entitlement, reported_revoked ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      allocated = Map.get(allocated_amounts([lot.id]), lot.id, 0)
      available = max(lot.remaining_cents - allocated, 0)
      revoked = min(entitlement.entitlement_cents, available)
      unrecovered = entitlement.entitlement_cents - revoked
      reporting_revoked = revoke_scheduled_credit(lot, revoked, posting_on)

      {:ok, _lot} =
        lot
        |> CreditLot.changeset(%{
          remaining_cents: lot.remaining_cents - revoked,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
        })
        |> Repo.update()

      {:ok, _entitlement} =
        entitlement
        |> CreditEntitlement.changeset(%{charged_back: true})
        |> Repo.update()

      reported_revoked + reporting_revoked
    end)
  end

  defp require_open_fields(operation) do
    required = [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    with :ok <- require_fields(operation, required),
         true <-
           Enum.all?(
             ["operation_id", "group_id", "guest_id", "property_id"],
             &usable_id?(operation[&1])
           ),
         true <- is_binary(operation["occurred_on"]),
         true <- is_binary(operation["arrival_on"]),
         true <- is_binary(operation["departure_on"]),
         true <- is_binary(operation["rate_plan"]),
         true <- is_list(operation["rooms"]),
         true <- Enum.all?(operation["rooms"], &complete_room?/1) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_update_fields(operation) do
    with :ok <- require_fields(operation, ["operation_id", "group_id"]),
         true <- usable_id?(operation["operation_id"]),
         true <- usable_id?(operation["group_id"]) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_fields(operation, fields) when is_map(operation) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)), do: :ok, else: {:error, :missing_data}
  end

  defp require_fields(_operation, _fields), do: {:error, :missing_data}

  defp usable_id?(value), do: is_binary(value) and value != ""

  defp complete_room?(room) when is_map(room) do
    Map.has_key?(room, "room_id") and Map.has_key?(room, "nightly_rate_cents")
  end

  defp complete_room?(_room), do: false

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_date}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan}
  end

  defp validate_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1["room_id"])

    valid =
      rooms != [] and
        Enum.all?(rooms, fn room ->
          usable_id?(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
            room["nightly_rate_cents"] > 0
        end) and Enum.uniq(room_ids) == room_ids

    if valid, do: {:ok, rooms}, else: {:error, :invalid_rooms}
  end

  defp detailed_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights

      due =
        if rate_plan == "flexible",
          do: percentage(lodging, 20),
          else: lodging

      room
      |> Map.put("status", "active")
      |> Map.put("lodging_total_cents", lodging)
      |> Map.put("deposit_due_cents", due)
    end)
  end

  defp active_rooms(group), do: Enum.filter(group.rooms["items"], &(&1["status"] == "active"))

  defp validate_cancelled_rooms(group, room_ids) when is_list(room_ids) do
    valid_shape =
      room_ids != [] and Enum.all?(room_ids, &usable_id?/1) and Enum.uniq(room_ids) == room_ids

    active_ids = MapSet.new(Enum.map(active_rooms(group), & &1["room_id"]))

    if valid_shape and Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
      requested = MapSet.new(room_ids)

      {:ok,
       group
       |> active_rooms()
       |> Enum.map(& &1["room_id"])
       |> Enum.filter(&MapSet.member?(requested, &1))}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_cancelled_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  defp room_funding_totals(group_id) do
    from(funding in RoomFunding,
      where: funding.group_id == ^group_id,
      group_by: [funding.room_id, funding.funding_type],
      select: {{funding.room_id, funding.funding_type}, sum(funding.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp allocate_cash_to_rooms(group, payment_operation_id, amount) do
    allocate_sources_to_rooms(group, [
      %{funding_type: "cash", payment_operation_id: payment_operation_id, amount_cents: amount}
    ])
  end

  defp allocate_credit_to_rooms(lots, group, amount) do
    {sources, _left} =
      Enum.map_reduce(lots, amount, fn %{lot: lot, remaining_cents: available}, left ->
        used = min(available, left)

        {%{funding_type: "credit", credit_lot_id: lot.id, amount_cents: used}, left - used}
      end)

    sources
    |> Enum.filter(&(&1.amount_cents > 0))
    |> then(&allocate_sources_to_rooms(group, &1))
  end

  defp allocate_sources_to_rooms(group, sources) do
    totals = room_funding_totals(group.group_id)

    room_states =
      Enum.map(active_rooms(group), fn room ->
        funded =
          Map.get(totals, {room["room_id"], "cash"}, 0) +
            Map.get(totals, {room["room_id"], "credit"}, 0)

        {room, funded}
      end)

    Enum.reduce(sources, room_states, fn source, states ->
      {states, 0} =
        Enum.map_reduce(states, source.amount_cents, fn {room, funded}, left ->
          used = min(max(room["deposit_due_cents"] - funded, 0), left)

          if used > 0 do
            attrs =
              source
              |> Map.take([:funding_type, :payment_operation_id, :credit_lot_id])
              |> Map.merge(%{
                group_id: group.group_id,
                room_id: room["room_id"],
                amount_cents: used
              })

            {:ok, _funding} =
              %RoomFunding{}
              |> RoomFunding.changeset(attrs)
              |> Repo.insert()
          end

          {{room, funded + used}, left - used}
        end)

      states
    end)

    :ok
  end

  defp settle_rooms(group, room_ids, operation, occurred_on, refundable, refund_method) do
    selected = MapSet.new(room_ids)

    rooms =
      Enum.filter(group.rooms["items"], fn room -> MapSet.member?(selected, room["room_id"]) end)

    fundings =
      from(funding in RoomFunding,
        where: funding.group_id == ^group.group_id and funding.room_id in ^room_ids,
        order_by: [asc: funding.id]
      )
      |> Repo.all()

    cash_fundings = Enum.filter(fundings, &(&1.funding_type == "cash"))
    credit_fundings = Enum.filter(fundings, &(&1.funding_type == "credit"))
    cash = Enum.sum_by(cash_fundings, & &1.amount_cents)
    credit = Enum.sum_by(credit_fundings, & &1.amount_cents)
    refunded = if refundable and refund_method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash
    converted = if refundable and refund_method == "hotel_credit", do: cash, else: 0
    contributors = cash_contributors(cash_fundings)

    update_settled_payments(group.group_id, contributors, refundable, refund_method)

    {credit_issued, issued_immediately_expired} =
      if converted > 0 do
        create_credit_lot(group, operation, occurred_on, contributors, converted)
      else
        {0, 0}
      end

    credit_settlement =
      credit_fundings
      |> Enum.map(
        &settle_credit_funding(
          &1,
          occurred_on,
          refundable,
          operation_posting_on(operation)
        )
      )
      |> Enum.reduce(%{expired: 0, consumed: 0, absorbed: 0}, fn effects, totals ->
        Map.merge(totals, effects, fn _key, left, right -> left + right end)
      end)

    Enum.each(cash_fundings, &Repo.delete!/1)

    updated_rooms =
      Enum.map(group.rooms["items"], fn room ->
        if MapSet.member?(selected, room["room_id"]),
          do: Map.put(room, "status", "cancelled"),
          else: room
      end)

    lodging = Enum.sum_by(rooms, & &1["lodging_total_cents"])
    due = Enum.sum_by(rooms, & &1["deposit_due_cents"])
    remaining_active? = Enum.any?(updated_rooms, &(&1["status"] == "active"))
    revision = group.revision + 1

    {:ok, _updated_group} =
      persist(group, %{
        rooms: %{"items" => updated_rooms},
        status: if(remaining_active?, do: "active", else: "cancelled"),
        lodging_total_cents: group.lodging_total_cents - lodging,
        deposit_due_cents: group.deposit_due_cents - due,
        deposit_paid_cents: group.deposit_paid_cents - cash - credit,
        cash_paid_cents: group.cash_paid_cents - cash,
        credit_paid_cents: group.credit_paid_cents - credit,
        cash_refunded_cents: group.cash_refunded_cents + refunded,
        cash_retained_cents: group.cash_retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: revision
      })

    record_cash_movements(operation, [
      {group.property_id, "refunded", refunded},
      {group.property_id, "retained", retained},
      {group.property_id, "converted_to_credit", converted}
    ])

    record_credit_movements(operation, [
      {"issued", credit_issued},
      {"expired", credit_settlement.expired + issued_immediately_expired},
      {"consumed", credit_settlement.consumed},
      {"absorbed", credit_settlement.absorbed}
    ])

    {:ok,
     %{
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: credit_issued,
       revision: revision
     }}
  end

  defp cash_contributors(fundings) do
    fundings
    |> Enum.reduce([], fn funding, contributors ->
      key = funding.payment_operation_id

      case Enum.find_index(contributors, &(elem(&1, 0) == key)) do
        nil ->
          contributors ++ [{key, funding.amount_cents}]

        index ->
          List.update_at(contributors, index, fn {^key, amount} ->
            {key, amount + funding.amount_cents}
          end)
      end
    end)
  end

  defp update_settled_payments(group_id, contributors, refundable, refund_method) do
    Enum.each(contributors, fn
      {nil, _amount} ->
        :ok

      {payment_operation_id, amount} ->
        payment = Repo.get!(PaymentDisposition, payment_operation_id)

        {attrs, disposition} =
          cond do
            refundable and refund_method == "cash" ->
              {%{
                 held_cents: payment.held_cents - amount,
                 refunded_cents: payment.refunded_cents + amount
               }, "refunded"}

            refundable ->
              {%{
                 held_cents: payment.held_cents - amount,
                 converted_to_credit_cents: payment.converted_to_credit_cents + amount
               }, "converted_to_credit"}

            true ->
              {%{
                 held_cents: payment.held_cents - amount,
                 retained_cents: payment.retained_cents + amount
               }, "retained"}
          end

        {:ok, _payment} = persist_payment(payment, attrs)

        {:ok, _settlement} =
          %PaymentSettlement{}
          |> PaymentSettlement.changeset(%{
            payment_operation_id: payment_operation_id,
            group_id: group_id,
            disposition: disposition,
            amount_cents: amount
          })
          |> Repo.insert()
    end)
  end

  defp create_credit_lot(group, operation, occurred_on, contributors, principal) do
    issued = principal + percentage(principal, 10)

    {:ok, lot} =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: issued,
        unrecovered_clawback_cents: 0,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert()

    reporting_expired =
      create_credit_expiry_schedule(lot, issued, operation_posting_on(operation))

    Enum.reduce(contributors, 0, fn {payment_operation_id, amount}, running ->
      next = running + amount
      entitlement = bonus_value(next) - bonus_value(running)

      {:ok, _entitlement} =
        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          principal_cents: amount,
          entitlement_cents: entitlement,
          charged_back: false
        })
        |> Repo.insert()

      next
    end)

    {issued, reporting_expired}
  end

  defp bonus_value(principal), do: principal + percentage(principal, 10)

  defp settle_credit_funding(funding, occurred_on, refundable, reporting_posting_on) do
    lot = Repo.get!(CreditLot, funding.credit_lot_id)

    effects =
      if refundable do
        absorbed = min(funding.amount_cents, lot.unrecovered_clawback_cents)
        excess = funding.amount_cents - absorbed
        expired = if Date.compare(lot.expires_on, occurred_on) == :lt, do: excess, else: 0
        restored = excess - expired

        {:ok, _lot} =
          lot
          |> CreditLot.changeset(%{
            remaining_cents: lot.remaining_cents - absorbed - expired,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
          })
          |> Repo.update()

        reporting_expired = restore_credit_expiry_schedule(lot, restored, reporting_posting_on)
        %{absorbed: absorbed, expired: expired + reporting_expired, consumed: 0}
      else
        {:ok, _lot} =
          lot
          |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - funding.amount_cents})
          |> Repo.update()

        %{absorbed: 0, expired: 0, consumed: funding.amount_cents}
      end

    {:ok, _funding} = Repo.delete(funding)
    effects
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  # The migration persists this field for old rows; the fallback is defensive for nullable
  # records imported by support tooling.
  defp effective_policy_version(%Group{policy_version: version}) when is_binary(version),
    do: version

  defp effective_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp policy_window("flex-14"), do: 14
  defp policy_window("flex-30"), do: 30

  defp refundable_until(group, arrival_on \\ nil)

  defp refundable_until(%Group{rate_plan: "advance_purchase"}, _arrival_on), do: nil

  defp refundable_until(group, arrival_on) do
    arrival_on = arrival_on || group.arrival_on
    Date.add(arrival_on, -policy_window(effective_policy_version(group))) |> Date.to_iso8601()
  end

  defp refundable?(%Group{rate_plan: "advance_purchase"}, _occurred_on), do: false

  defp refundable?(group, occurred_on) do
    Date.compare(
      occurred_on,
      Date.add(group.arrival_on, -policy_window(effective_policy_version(group)))
    ) in [
      :lt,
      :eq
    ]
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp refund_method_available(_method, _refundable), do: :ok

  defp percentage(amount, percent), do: div(amount * percent + 50, 100)

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp enough_credit(guest_id, amount, on) do
    lots = available_lots(guest_id, on)

    if Enum.sum_by(lots, & &1.remaining_cents) >= amount do
      {:ok, lots}
    else
      {:error, :insufficient_credit}
    end
  end

  defp available_lots(guest_id, on) do
    lots =
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    allocated = allocated_amounts(Enum.map(lots, & &1.id))

    lots
    |> Enum.map(fn lot ->
      %{lot: lot, remaining_cents: lot.remaining_cents - Map.get(allocated, lot.id, 0)}
    end)
    |> Enum.filter(&(&1.remaining_cents > 0))
  end

  defp allocated_amounts([]), do: %{}

  defp allocated_amounts(lot_ids) do
    from(funding in RoomFunding,
      where: funding.credit_lot_id in ^lot_ids and funding.funding_type == "credit",
      group_by: funding.credit_lot_id,
      select: {funding.credit_lot_id, sum(funding.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp credit_liability(on) do
    lots = Repo.all(CreditLot)
    allocated = allocated_amounts(Enum.map(lots, & &1.id))

    Enum.sum_by(lots, fn lot ->
      if Date.compare(lot.expires_on, on) == :lt do
        Map.get(allocated, lot.id, 0)
      else
        lot.remaining_cents
      end
    end)
  end

  defp credit_shortfall do
    allocated =
      from(funding in RoomFunding,
        where: funding.funding_type == "credit",
        group_by: funding.credit_lot_id,
        select: {funding.credit_lot_id, sum(funding.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    Repo.all(CreditLot)
    |> Enum.sum_by(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(allocated, lot.id, 0))
    end)
  end

  defp serialize_lot(%{lot: lot, remaining_cents: remaining_cents}) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp initialize_opening_cash do
    from(group in Group,
      group_by: group.property_id,
      having: sum(group.cash_paid_cents) != 0,
      select: {group.property_id, sum(group.cash_paid_cents)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, amount} ->
      %FinanceOpeningCash{}
      |> FinanceOpeningCash.changeset(%{
        property_id: property_id,
        opening_held_cents: amount
      })
      |> Repo.insert!()
    end)
  end

  defp initialize_credit_expiry_schedules(starts_on) do
    lots = Repo.all(CreditLot)
    allocated = allocated_amounts(Enum.map(lots, & &1.id))

    Enum.each(lots, fn lot ->
      available = max(lot.remaining_cents - Map.get(allocated, lot.id, 0), 0)

      if available > 0 and Date.compare(lot.expires_on, starts_on) != :lt do
        insert_credit_expiry_schedule(lot, available)
      end
    end)
  end

  defp create_credit_expiry_schedule(lot, amount, posting_on) do
    if Repo.get(FinanceReporting, 1) && amount > 0 do
      expiry_posting = Date.add(lot.expires_on, 1)

      if Date.compare(expiry_posting, posting_on) in [:lt, :eq] do
        amount
      else
        insert_credit_expiry_schedule(lot, amount)
        0
      end
    else
      0
    end
  end

  defp insert_credit_expiry_schedule(lot, amount) do
    %CreditExpirySchedule{}
    |> CreditExpirySchedule.changeset(%{
      credit_lot_id: lot.id,
      posting_on: Date.add(lot.expires_on, 1),
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp consume_credit_expiry_schedules(operation, lots, amount) do
    if Repo.get(FinanceReporting, 1) do
      {restored_expired, _left} =
        Enum.map_reduce(lots, amount, fn %{lot: lot, remaining_cents: available}, left ->
          used = min(available, left)
          restored = consume_credit_expiry_schedule(operation, lot, used)
          {restored, left - used}
        end)

      Enum.sum(restored_expired)
    else
      0
    end
  end

  defp consume_credit_expiry_schedule(_operation, _lot, 0), do: 0

  defp consume_credit_expiry_schedule(operation, lot, amount) do
    schedule = Repo.get(CreditExpirySchedule, lot.id)

    case {schedule, operation_reporting_posting(operation)} do
      {%CreditExpirySchedule{} = schedule, {posting_on, true}} ->
        if Date.compare(schedule.posting_on, posting_on) in [:lt, :eq] do
          min(amount, schedule.amount_cents)
        else
          change_credit_expiry_schedule(lot.id, -amount)
          0
        end

      {%CreditExpirySchedule{}, _posting} ->
        change_credit_expiry_schedule(lot.id, -amount)
        0

      {nil, {posting_on, _late_adjustment}} ->
        expiry_posting_on = Date.add(lot.expires_on, 1)
        if Date.compare(expiry_posting_on, posting_on) in [:lt, :eq], do: amount, else: 0

      {nil, nil} ->
        0
    end
  end

  defp restore_credit_expiry_schedule(_lot, 0, _posting_on), do: 0

  defp restore_credit_expiry_schedule(lot, amount, posting_on) do
    if Repo.get(FinanceReporting, 1) do
      expiry_posting = Date.add(lot.expires_on, 1)

      if Date.compare(expiry_posting, posting_on) in [:lt, :eq] do
        amount
      else
        change_credit_expiry_schedule(lot.id, amount, lot)
        0
      end
    else
      0
    end
  end

  defp revoke_scheduled_credit(_lot, 0, _posting_on), do: 0

  defp revoke_scheduled_credit(lot, amount, posting_on) do
    case Repo.get(CreditExpirySchedule, lot.id) do
      %CreditExpirySchedule{} = schedule ->
        if Date.compare(posting_on, schedule.posting_on) == :lt do
          revoked = min(amount, schedule.amount_cents)
          change_credit_expiry_schedule(lot.id, -revoked)
          revoked
        else
          0
        end

      nil ->
        0
    end
  end

  defp change_credit_expiry_schedule(lot_id, change, lot \\ nil)
  defp change_credit_expiry_schedule(_lot_id, 0, _lot), do: :ok

  defp change_credit_expiry_schedule(lot_id, change, lot) do
    schedule = Repo.get(CreditExpirySchedule, lot_id)

    cond do
      schedule ->
        schedule
        |> CreditExpirySchedule.changeset(%{amount_cents: schedule.amount_cents + change})
        |> Repo.update!()

      change > 0 and lot ->
        insert_credit_expiry_schedule(lot, change)

      true ->
        raise "credit expiry schedule is inconsistent"
    end
  end

  defp operation_posting_on(operation) do
    case operation_reporting_posting(operation) do
      {posting_on, _late_adjustment} -> posting_on
      nil -> nil
    end
  end

  defp operation_reporting_posting(operation) do
    case Repo.get(FinanceReporting, 1) do
      %FinanceReporting{starts_on: starts_on} ->
        occurred_on =
          case parse_date(Map.get(operation, "occurred_on")) do
            {:ok, date} -> date
            _ -> starts_on
          end

        ordinary_posting_on = later_date(occurred_on, starts_on)

        case latest_period_end_on() do
          nil ->
            {ordinary_posting_on, false}

          period_end_on ->
            first_open_on = Date.add(period_end_on, 1)
            posting_on = later_date(ordinary_posting_on, first_open_on)
            {posting_on, Date.compare(posting_on, ordinary_posting_on) == :gt}
        end

      nil ->
        nil
    end
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp latest_period_end_on do
    from(close in FinancePeriodClose,
      order_by: [desc: close.period_end_on],
      limit: 1,
      select: close.period_end_on
    )
    |> Repo.one()
  end

  defp record_cash_movements(operation, movements) do
    movements
    |> Enum.group_by(fn {property_id, classification, _amount} ->
      {property_id, classification}
    end)
    |> Enum.map(fn {{property_id, classification}, rows} ->
      {property_id, classification, Enum.sum_by(rows, &elem(&1, 2))}
    end)
    |> Enum.each(fn {property_id, classification, amount} ->
      insert_finance_movement(operation, "cash", property_id, classification, amount)
    end)
  end

  defp record_credit_movements(operation, movements) do
    Enum.each(movements, fn {classification, amount} ->
      insert_finance_movement(operation, "credit", nil, classification, amount)
    end)
  end

  defp insert_finance_movement(_operation, _scope, _property_id, _classification, 0), do: :ok

  defp insert_finance_movement(operation, scope, property_id, classification, amount) do
    case operation_reporting_posting(operation) do
      nil ->
        :ok

      {posting_on, late_adjustment} ->
        %FinanceMovement{}
        |> FinanceMovement.changeset(%{
          operation_id: operation["operation_id"],
          posting_on: posting_on,
          scope: scope,
          property_id: property_id,
          classification: classification,
          amount_cents: amount,
          late_adjustment: late_adjustment
        })
        |> Repo.insert!()
    end
  end

  defp record_group_cash_movements(operation, amounts_by_group, classification) do
    movements =
      Enum.map(amounts_by_group, fn {group_id, amount} ->
        {Repo.get!(Group, group_id).property_id, classification, amount}
      end)

    record_cash_movements(operation, movements)
  end

  defp record_chargeback_cash_movements(operation, removed_by_group, settlements_by_group) do
    held =
      Enum.map(removed_by_group, fn {group_id, amount} ->
        {Repo.get!(Group, group_id).property_id, "charged_back", amount}
      end)

    settled =
      Enum.flat_map(settlements_by_group, fn {group_id, dispositions} ->
        property_id = Repo.get!(Group, group_id).property_id

        Enum.flat_map(dispositions, fn {classification, amount} ->
          [
            {property_id, classification, -amount},
            {property_id, "charged_back", amount}
          ]
        end)
      end)

    record_cash_movements(operation, held ++ settled)
  end

  defp normalize_reporting_date(date) do
    case parse_date(date) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_reporting_date}
    end
  end

  defp report_available(reporting, date) do
    if Date.compare(date, reporting.starts_on) == :lt,
      do: {:error, :report_not_available},
      else: :ok
  end

  @cash_classifications ~w(received transferred_in transferred_out refunded retained
                           converted_to_credit reduced charged_back)
  @credit_classifications ~w(issued expired consumed revoked absorbed)

  defp build_daily_finance_report(reporting, date) do
    cash_openings =
      Repo.all(FinanceOpeningCash)
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    cash_movements =
      from(movement in FinanceMovement,
        where: movement.scope == "cash" and movement.posting_on <= ^date
      )
      |> Repo.all()

    properties =
      (Map.keys(cash_openings) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&build_cash_report(&1, date, cash_openings, cash_movements))

    late_cash = Enum.map(properties, &build_late_cash_report(&1, date, cash_movements))

    cash =
      cash
      |> Enum.zip(late_cash)
      |> Enum.reject(fn {cash_report, late_report} ->
        empty_cash_report?(cash_report) and empty_movements?(late_report.movements)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash = Enum.reject(late_cash, &empty_movements?(&1.movements))

    credit_movements =
      from(movement in FinanceMovement,
        where: movement.scope == "credit" and movement.posting_on <= ^date
      )
      |> Repo.all()

    expiries =
      from(schedule in CreditExpirySchedule,
        where: schedule.posting_on <= ^date and schedule.amount_cents != 0
      )
      |> Repo.all()

    credit = build_credit_report(reporting, date, credit_movements, expiries)

    late_credit = build_late_credit_report(date, credit_movements)

    status =
      case latest_period_end_on() do
        nil -> "open"
        cutoff -> if Date.compare(date, cutoff) in [:lt, :eq], do: "closed", else: "open"
      end

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp build_cash_report(property_id, date, openings, all_movements) do
    property_movements = Enum.filter(all_movements, &(&1.property_id == property_id))

    prior_delta =
      property_movements
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :lt))
      |> Enum.sum_by(&cash_delta/1)

    opening = Map.get(openings, property_id, 0) + prior_delta

    movements =
      @cash_classifications
      |> Map.new(fn classification ->
        amount =
          property_movements
          |> Enum.filter(
            &(not &1.late_adjustment and Date.compare(&1.posting_on, date) == :eq and
                &1.classification == classification)
          )
          |> Enum.sum_by(& &1.amount_cents)

        {String.to_atom(classification <> "_cents"), amount}
      end)

    closing =
      opening +
        Enum.sum_by(property_movements, fn movement ->
          if Date.compare(movement.posting_on, date) == :eq, do: cash_delta(movement), else: 0
        end)

    %{
      property_id: property_id,
      opening_held_cents: opening,
      movements: movements,
      closing_held_cents: closing
    }
  end

  defp build_late_cash_report(property_id, date, all_movements) do
    movements =
      @cash_classifications
      |> Map.new(fn classification ->
        amount =
          all_movements
          |> Enum.filter(
            &(&1.late_adjustment and &1.property_id == property_id and
                Date.compare(&1.posting_on, date) == :eq and
                &1.classification == classification)
          )
          |> Enum.sum_by(& &1.amount_cents)

        {String.to_atom(classification <> "_cents"), amount}
      end)

    %{property_id: property_id, movements: movements}
  end

  defp empty_movements?(movements) do
    Enum.all?(movements, fn {_key, amount} -> amount == 0 end)
  end

  defp empty_cash_report?(report) do
    report.opening_held_cents == 0 and report.closing_held_cents == 0 and
      Enum.all?(report.movements, fn {_key, amount} -> amount == 0 end)
  end

  defp cash_delta(%FinanceMovement{classification: classification, amount_cents: amount})
       when classification in ["received", "transferred_in"],
       do: amount

  defp cash_delta(%FinanceMovement{amount_cents: amount}), do: -amount

  defp build_credit_report(reporting, date, movements, expiries) do
    prior_movement_delta =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :lt))
      |> Enum.sum_by(&credit_delta/1)

    prior_expired =
      expiries
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :lt))
      |> Enum.sum_by(& &1.amount_cents)

    opening = reporting.opening_credit_liability_cents + prior_movement_delta - prior_expired

    report_movements =
      @credit_classifications
      |> Map.new(fn classification ->
        recorded =
          movements
          |> Enum.filter(
            &(not &1.late_adjustment and Date.compare(&1.posting_on, date) == :eq and
                &1.classification == classification)
          )
          |> Enum.sum_by(& &1.amount_cents)

        scheduled =
          if classification == "expired" do
            expiries
            |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
            |> Enum.sum_by(& &1.amount_cents)
          else
            0
          end

        {String.to_atom(classification <> "_cents"), recorded + scheduled}
      end)

    recorded_delta =
      movements
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
      |> Enum.sum_by(&credit_delta/1)

    scheduled_expired =
      expiries
      |> Enum.filter(&(Date.compare(&1.posting_on, date) == :eq))
      |> Enum.sum_by(& &1.amount_cents)

    closing = opening + recorded_delta - scheduled_expired

    %{
      opening_liability_cents: opening,
      movements: report_movements,
      closing_liability_cents: closing
    }
  end

  defp build_late_credit_report(date, movements) do
    @credit_classifications
    |> Map.new(fn classification ->
      amount =
        movements
        |> Enum.filter(
          &(&1.late_adjustment and Date.compare(&1.posting_on, date) == :eq and
              &1.classification == classification)
        )
        |> Enum.sum_by(& &1.amount_cents)

      {String.to_atom(classification <> "_cents"), amount}
    end)
  end

  defp credit_delta(%FinanceMovement{classification: "issued", amount_cents: amount}),
    do: amount

  defp credit_delta(%FinanceMovement{amount_cents: amount}), do: -amount

  defp normalize_date(%Date{} = date), do: {:ok, date}
  defp normalize_date(date), do: parse_date(date)

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error, :stale_revision, group}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp valid_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_amount(_amount), do: {:error, :invalid_amount}

  defp not_excessive(amount, outstanding) when amount <= outstanding, do: :ok
  defp not_excessive(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp serialize_group(group) do
    funding_totals = room_funding_totals(group.group_id)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: effective_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: serialize_rooms(group.rooms["items"], funding_totals),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp serialize_rooms(rooms, funding_totals) do
    Enum.map(rooms, fn room ->
      active? = room["status"] == "active"

      %{
        room_id: room["room_id"],
        nightly_rate_cents: room["nightly_rate_cents"],
        status: room["status"],
        lodging_total_cents: room["lodging_total_cents"],
        deposit_due_cents: room["deposit_due_cents"],
        cash_paid_cents:
          if(active?, do: Map.get(funding_totals, {room["room_id"], "cash"}, 0), else: 0),
        credit_paid_cents:
          if(active?, do: Map.get(funding_totals, {room["room_id"], "credit"}, 0), else: 0)
      }
    end)
  end

  defp serialize_payment(payment) do
    statement = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.original_group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.transfer_participated do
      Map.put(statement, :held_by_group, held_cash_by_group(payment.payment_operation_id))
    else
      statement
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    from(funding in RoomFunding,
      where:
        funding.payment_operation_id == ^payment_operation_id and
          funding.funding_type == "cash",
      group_by: funding.group_id,
      order_by: funding.group_id,
      select: %{group_id: funding.group_id, amount_cents: sum(funding.amount_cents)}
    )
    |> Repo.all()
  end

  defp stale_revision(operation, group) do
    reject(operation, "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    )
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})
  end

  defp reject(operation, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "rejected", code: code})
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
end
