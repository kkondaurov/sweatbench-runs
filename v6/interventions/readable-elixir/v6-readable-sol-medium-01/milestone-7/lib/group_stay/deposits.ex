defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations and exposes the deposit read model.

  Room allocations are the source of truth for active funding. Cash-payment
  dispositions preserve the identity of durable provider reports after their
  money is reduced, settled, converted to credit, or charged back.

  A batch is intentionally not one transaction. Each operation and its durable
  receipt commit together, so retries are idempotent and later operations can
  observe earlier changes from the same batch.
  """

  import Ecto.Query

  alias GroupStay.Deposits.{
    CashPayment,
    CashSettlement,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    PartnerOperation,
    Room,
    RoomAllocation
  }

  alias GroupStay.Repo
  alias GroupStay.FinanceReporting

  @rate_plans ~w(flexible advance_purchase)
  @new_flexible_policy_date ~D[2027-01-01]

  @doc "Applies partner operations in their original order."
  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  @doc "Returns the result durably recorded for a partner operation."
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  def get_operation(_), do: {:error, :operation_not_found}

  @doc "Returns the current dispositions of a durably recorded cash payment."
  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      %{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        payment = Repo.get_by!(CashPayment, operation_id: operation_id)
        {:ok, render_payment(payment)}

      _operation ->
        {:error, :payment_not_reconcilable}
    end
  end

  def get_payment(_), do: {:error, :operation_not_found}

  @doc "Returns an API-ready representation of a group."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group |> Repo.preload(rooms: :allocations) |> render_group()}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  @doc "Returns available credit lots for a guest as of the supplied date."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  @doc "Returns cash classifications, credit liability, and current credit shortfall."
  def ledger(on \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0)
          }
      )

    available_liability =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_liability =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    credit_shortfall =
      Repo.all(
        from l in CreditLot,
          left_join: a in CreditAllocation,
          on: a.credit_lot_id == l.id,
          group_by: l.id,
          select:
            fragment(
              "MIN(?, COALESCE(SUM(?), 0))",
              l.unrecovered_clawback_cents,
              a.amount_cents
            )
      )
      |> Enum.sum()

    cash_totals
    |> Map.new(fn {key, value} -> {key, value || 0} end)
    |> Map.put(:credit_liability_cents, (available_liability || 0) + (applied_liability || 0))
    |> Map.put(:credit_shortfall_cents, credit_shortfall)
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    case valid_operation_id(operation_id) do
      :ok -> process_idempotently(operation_id, operation)
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp process_operation(_), do: rejection(nil, :invalid_operation)

  defp process_idempotently(operation_id, submission) do
    mode = if Repo.in_transaction?(), do: :savepoint, else: :immediate

    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get_by(PartnerOperation, operation_id: operation_id) do
            nil -> process_and_remember(operation_id, submission)
            receipt -> replay_or_reject(receipt, submission)
          end
        end,
        mode: mode
      )

    result
  end

  defp process_and_remember(operation_id, submission) do
    result = process_fresh(operation_id, submission)

    %PartnerOperation{}
    |> PartnerOperation.changeset(%{
      operation_id: operation_id,
      operation_type: operation_type(submission),
      submission: submission,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp replay_or_reject(%PartnerOperation{submission: submission, result: result}, submission),
    do: result

  defp replay_or_reject(receipt, _submission),
    do: rejection(receipt.operation_id, :operation_id_conflict)

  defp process_fresh(operation_id, operation) do
    case dispatch(operation) do
      {:ok, result} -> Map.merge(%{operation_id: operation_id, status: "applied"}, result)
      {:error, code} -> rejection(operation_id, code)
      {:error, code, details} -> Map.merge(rejection(operation_id, code), details)
    end
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_submission), do: nil

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp dispatch(%{"type" => "close_finance_period"} = operation),
    do: close_finance_period(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: with_group(operation, &record_cash_payment/3)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: with_group(operation, &apply_hotel_credit/3)

  defp dispatch(%{"type" => "reschedule_group"} = operation),
    do: with_group(operation, &reschedule_group/3)

  defp dispatch(%{"type" => "cancel_group"} = operation),
    do: with_group(operation, &cancel_group/3)

  defp dispatch(%{"type" => "cancel_rooms"} = operation),
    do: with_group(operation, &cancel_rooms/3)

  defp dispatch(%{"type" => "transfer_deposit"} = operation),
    do: with_transfer_groups(operation, &transfer_deposit/3)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: with_payment(operation, :payment_not_reducible, &reduce_cash_payment/3)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: with_payment(operation, :payment_not_chargeable, &charge_back_payment/3)

  defp dispatch(_operation), do: {:error, :invalid_operation}

  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation) do
      transaction(fn ->
        case FinanceReporting.start(starts_on) do
          :ok -> %{starts_on: starts_on}
          {:error, code} when is_atom(code) -> rollback(code)
          {:error, _changeset} -> rollback(:invalid_operation)
        end
      end)
    end
  end

  defp close_finance_period(operation) do
    with {:ok, period_end_on} <- required_date(operation, "period_end_on") do
      transaction(fn ->
        case FinanceReporting.close(period_end_on) do
          :ok -> %{period_end_on: period_end_on}
          {:error, code} when is_atom(code) -> rollback(code)
          {:error, _changeset} -> rollback(:invalid_operation)
        end
      end)
    else
      {:error, _code} -> {:error, :invalid_period}
    end
  end

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      transaction(fn ->
        if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
          do: rollback(:group_already_exists)

        with {:ok, booked_on} <- required_date(operation, "occurred_on"),
             {:ok, guest_id} <- required_identifier(operation, "guest_id"),
             {:ok, property_id} <- required_identifier(operation, "property_id"),
             {:ok, arrival_on} <- domain_date(operation, "arrival_on"),
             {:ok, departure_on} <- domain_date(operation, "departure_on"),
             :ok <- valid_stay(arrival_on, departure_on),
             {:ok, rate_plan} <- rate_plan(operation),
             {:ok, requested_rooms} <- rooms(operation),
             nights = Date.diff(departure_on, arrival_on),
             rooms = price_rooms(requested_rooms, nights, rate_plan),
             lodging_total = sum_field(rooms, :lodging_total_cents),
             deposit_due = sum_field(rooms, :deposit_due_cents),
             {:ok, group} <-
               insert_group(%{
                 group_id: group_id,
                 guest_id: guest_id,
                 property_id: property_id,
                 booked_on: booked_on,
                 arrival_on: arrival_on,
                 departure_on: departure_on,
                 rate_plan: rate_plan,
                 policy_version: policy_version(rate_plan, booked_on),
                 status: "active",
                 revision: 1,
                 lodging_total_cents: lodging_total,
                 deposit_due_cents: deposit_due,
                 deposit_paid_cents: 0,
                 cash_paid_cents: 0,
                 credit_paid_cents: 0,
                 cash_refunded_cents: 0,
                 cash_retained_cents: 0,
                 cash_converted_to_credit_cents: 0,
                 cash_reduced_cents: 0,
                 cash_charged_back_cents: 0
               }),
             :ok <- insert_rooms(group, rooms) do
          %{group_id: group_id, deposit_due_cents: deposit_due, revision: 1}
        else
          {:error, code} when is_atom(code) -> rollback(code)
          {:error, _changeset} -> rollback(:invalid_operation)
        end
      end)
    end
  end

  # Group existence and revision are deliberately checked before other domain rules.
  defp with_group(operation, callback) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> rollback(:group_not_found)
          group -> checked_group_callback(group, operation, callback)
        end
      end)
    end
  end

  # Payment-derived operations resolve the durable target before checking the
  # revision of its original group.
  defp with_payment(operation, wrong_type_code, callback) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      transaction(fn ->
        case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
          nil ->
            rollback(:operation_not_found)

          %{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
            payment = Repo.get_by!(CashPayment, operation_id: payment_operation_id)
            group = Repo.get!(Group, payment.group_record_id)

            checked_group_callback(group, operation, fn group, operation, occurred_on ->
              callback.(Repo.reload(payment), group, {operation, occurred_on})
            end)

          _operation ->
            rollback(wrong_type_code)
        end
      end)
    end
  end

  # A transfer addresses two aggregates. Existence and revision guards are
  # intentionally resolved in request order before any transfer validation.
  defp with_transfer_groups(operation, callback) do
    with {:ok, source_id} <- required_identifier(operation, "source_group_id") do
      transaction(fn ->
        source =
          Repo.get_by(Group, group_id: source_id) ||
            rollback({:group_not_found, %{group_id: source_id}})

        with {:ok, destination_id} <- required_identifier(operation, "destination_group_id") do
          destination =
            Repo.get_by(Group, group_id: destination_id) ||
              rollback({:group_not_found, %{group_id: destination_id}})

          check_transfer_revision!(source, operation, "expected_revision")

          check_transfer_revision!(
            destination,
            operation,
            "destination_expected_revision"
          )

          case required_date(operation, "occurred_on") do
            {:ok, occurred_on} -> callback.(source, destination, {operation, occurred_on})
            {:error, code} -> rollback(code)
          end
        else
          {:error, code} -> rollback(code)
        end
      end)
    end
  end

  defp checked_group_callback(group, operation, callback) do
    case check_revision(group, operation) do
      :ok ->
        case required_date(operation, "occurred_on") do
          {:ok, occurred_on} -> callback.(group, operation, occurred_on)
          {:error, code} -> rollback(code)
        end

      {:error, code, details} ->
        rollback({code, details})

      {:error, code} ->
        rollback(code)
    end
  end

  defp record_cash_payment(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         :ok <- does_not_exceed(amount, outstanding(group)),
         :ok <- allocate_cash(group, amount, operation["operation_id"]),
         {:ok, _payment} <- insert_cash_payment(group, operation["operation_id"], amount),
         :ok <-
           FinanceReporting.record_cash(
             FinanceReporting.posting(occurred_on),
             group.property_id,
             "received",
             amount
           ),
         {:ok, updated} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             cash_paid_cents: group.cash_paid_cents + amount,
             revision: group.revision + 1
           }) do
      payment_result(updated, amount)
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp apply_hotel_credit(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         :ok <- does_not_exceed(amount, outstanding(group)),
         lots = available_lots(group.guest_id, occurred_on),
         :ok <- enough_credit(lots, amount),
         :ok <- consume_and_allocate_credit(group, lots, amount, occurred_on),
         {:ok, updated} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + amount,
             revision: group.revision + 1
           }) do
      payment_result(updated, amount)
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, new_arrival_on} <- reschedule_date(operation),
         :ok <- future_arrival(new_arrival_on, occurred_on),
         stay_length = Date.diff(group.departure_on, group.arrival_on),
         new_departure_on = Date.add(new_arrival_on, stay_length),
         {:ok, updated} <-
           update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           }) do
      %{
        group_id: group.group_id,
        new_arrival_on: updated.arrival_on,
        new_departure_on: updated.departure_on,
        policy_version: group_policy_version(updated),
        refundable_until: refundable_until(updated),
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp cancel_group(group, operation, occurred_on) do
    with :ok <- active(group) do
      room_ids =
        Repo.all(
          from r in Room,
            where: r.group_record_id == ^group.id and r.status == "active",
            order_by: r.position,
            select: r.room_id
        )

      settle_rooms(group, operation, occurred_on, room_ids, false)
    else
      {:error, code} -> rollback(code)
    end
  end

  defp cancel_rooms(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, room_ids} <- selected_room_ids(operation),
         {:ok, ordered_ids} <- validate_selected_rooms(group, room_ids) do
      settle_rooms(group, operation, occurred_on, ordered_ids, true)
    else
      {:error, code} -> rollback(code)
    end
  end

  defp settle_rooms(group, operation, occurred_on, room_ids, include_room_ids?) do
    with {:ok, method} <- refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available(method, refundable?),
         rooms <- load_rooms(group.id, room_ids),
         cash_allocations <- allocations(rooms, "cash"),
         credit_allocations <- allocations(rooms, "credit"),
         cash = sum_field(cash_allocations, :amount_cents),
         credit = sum_field(credit_allocations, :amount_cents),
         due = sum_field(rooms, :deposit_due_cents),
         lodging = sum_field(rooms, :lodging_total_cents),
         :ok <- settle_credit_allocations(group, credit_allocations, occurred_on, refundable?),
         {:ok, credit_issued} <-
           settle_cash_allocations(
             group,
             cash_allocations,
             operation,
             occurred_on,
             method,
             refundable?
           ),
         :ok <-
           record_cash_settlement_movement(group, occurred_on, cash, method, refundable?),
         :ok <- delete_allocations(cash_allocations),
         :ok <- cancel_room_records(rooms),
         refunded = if(refundable? and method == "cash", do: cash, else: 0),
         retained = if(refundable?, do: 0, else: cash),
         converted = if(refundable? and method == "hotel_credit", do: cash, else: 0),
         remaining_rooms? <- active_rooms?(group.id),
         {:ok, updated} <-
           update_group(group, %{
             status: if(remaining_rooms?, do: "active", else: "cancelled"),
             lodging_total_cents: group.lodging_total_cents - lodging,
             deposit_due_cents: group.deposit_due_cents - due,
             deposit_paid_cents: group.deposit_paid_cents - cash - credit,
             cash_paid_cents: group.cash_paid_cents - cash,
             credit_paid_cents: group.credit_paid_cents - credit,
             cash_refunded_cents: group.cash_refunded_cents + refunded,
             cash_retained_cents: group.cash_retained_cents + retained,
             cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
             revision: group.revision + 1
           }) do
      result = %{
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: updated.revision
      }

      if include_room_ids?, do: Map.put(result, :cancelled_room_ids, room_ids), else: result
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp reduce_cash_payment(payment, group, {operation, occurred_on}) do
    held = held_cents(payment.operation_id)

    with :ok <- reducible(held),
         {:ok, amount} <- reduction_amount(operation),
         :ok <- reduction_does_not_exceed(amount, held),
         {:ok, removals} <- remove_held_cash(payment.operation_id, amount),
         :ok <- record_removed_cash(removals, occurred_on, "reduced"),
         {:ok, _payment} <-
           update_cash_payment(payment, %{reduced_cents: payment.reduced_cents + amount}),
         {:ok, updated} <-
           update_groups_after_cash_removal(removals, group, %{
             cash_reduced_cents: group.cash_reduced_cents + amount
           }) do
      %{
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp charge_back_payment(payment, group, {_operation, occurred_on}) do
    held = held_cents(payment.operation_id)
    remaining = payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents
    settlement_adjustments = cash_settlement_adjustments(payment.operation_id)

    with :ok <- chargeable(payment, remaining),
         {:ok, removals} <- remove_held_cash(payment.operation_id, held),
         :ok <- record_removed_cash(removals, occurred_on, "charged_back"),
         :ok <- record_settlement_chargebacks(settlement_adjustments, occurred_on),
         :ok <- revoke_credit_entitlements(payment.operation_id, occurred_on),
         :ok <- clear_cash_settlements(payment.operation_id),
         {:ok, _payment} <-
           update_cash_payment(payment, %{
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: payment.charged_back_cents + remaining
           }),
         {:ok, updated} <-
           update_groups_after_cash_removal(
             removals,
             group,
             %{
               cash_charged_back_cents: group.cash_charged_back_cents + remaining
             },
             settlement_adjustments
           ) do
      %{
        payment_operation_id: payment.operation_id,
        group_id: group.group_id,
        charged_back_cents: remaining,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp transfer_deposit(source, destination, {operation, occurred_on}) do
    with :ok <- transfer_group_active(source),
         :ok <- transfer_group_active(destination),
         :ok <- valid_transfer_parties(source, destination),
         {:ok, amount} <- transfer_amount(operation),
         :ok <- transfer_does_not_exceed_held(amount, source.deposit_paid_cents),
         :ok <- transfer_does_not_exceed_outstanding(amount, outstanding(destination)),
         {:ok, moved} <- draw_transfer_allocations(source, amount),
         :ok <- allocate_transferred_funding(destination, moved),
         :ok <- move_credit_allocation_totals(source, destination, moved),
         :ok <- mark_transferred_payments(moved),
         cash = moved_amount(moved, "cash"),
         credit = moved_amount(moved, "credit"),
         posting = FinanceReporting.posting(occurred_on),
         :ok <-
           FinanceReporting.record_cash(
             posting,
             source.property_id,
             "transferred_out",
             cash
           ),
         :ok <-
           FinanceReporting.record_cash(
             posting,
             destination.property_id,
             "transferred_in",
             cash
           ),
         {:ok, updated_source} <-
           update_group(source, %{
             deposit_paid_cents: source.deposit_paid_cents - amount,
             cash_paid_cents: source.cash_paid_cents - cash,
             credit_paid_cents: source.credit_paid_cents - credit,
             revision: source.revision + 1
           }),
         {:ok, updated_destination} <-
           update_group(destination, %{
             deposit_paid_cents: destination.deposit_paid_cents + amount,
             cash_paid_cents: destination.cash_paid_cents + cash,
             credit_paid_cents: destination.credit_paid_cents + credit,
             revision: destination.revision + 1
           }) do
      %{
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: amount,
        source_outstanding_deposit_cents: outstanding(updated_source),
        destination_outstanding_deposit_cents: outstanding(updated_destination),
        source_revision: updated_source.revision,
        destination_revision: updated_destination.revision
      }
    else
      {:error, code} when is_atom(code) -> rollback(code)
      {:error, code, details} -> rollback({code, details})
      {:error, _changeset} -> rollback(:invalid_operation)
    end
  end

  defp allocate_cash(group, amount, operation_id),
    do:
      allocate_to_rooms(group, amount, %{funding_type: "cash", payment_operation_id: operation_id})

  defp consume_and_allocate_credit(group, lots, amount, occurred_on) do
    posting = FinanceReporting.posting(occurred_on)

    Enum.reduce_while(lots, amount, fn
      _lot, 0 ->
        {:halt, 0}

      lot, remaining ->
        redeemed = min(lot.remaining_cents, remaining)

        with {:ok, _lot} <-
               lot
               |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - redeemed})
               |> Repo.update(),
             :ok <- FinanceReporting.adjust_scheduled_expiry(lot, posting, -redeemed),
             :ok <- add_credit_allocation(group, lot, redeemed),
             :ok <-
               allocate_to_rooms(group, redeemed, %{funding_type: "credit", credit_lot_id: lot.id}) do
          {:cont, remaining - redeemed}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
    end)
    |> case do
      0 -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp allocate_to_rooms(group, amount, attrs) do
    rooms =
      Repo.all(
        from r in Room,
          where: r.group_record_id == ^group.id and r.status == "active",
          order_by: r.position,
          preload: [:allocations]
      )

    start_order = (Repo.aggregate(RoomAllocation, :max, :allocation_order) || 0) + 1

    Enum.reduce_while(rooms, {amount, start_order}, fn room, {remaining, order} ->
      if remaining == 0 do
        {:halt, {0, order}}
      else
        funded = sum_field(room.allocations, :amount_cents)
        allocated = min(remaining, room.deposit_due_cents - funded)

        if allocated > 0 do
          result =
            %RoomAllocation{}
            |> RoomAllocation.changeset(
              attrs
              |> Map.merge(%{room_id: room.id, amount_cents: allocated, allocation_order: order})
            )
            |> Repo.insert()

          case result do
            {:ok, _allocation} -> {:cont, {remaining - allocated, order + 1}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        else
          {:cont, {remaining, order}}
        end
      end
    end)
    |> case do
      {0, _order} -> :ok
      {:error, changeset} -> {:error, changeset}
      _ -> {:error, :payment_exceeds_outstanding}
    end
  end

  # Transfer chunks retain their cash-payment or credit-lot identity. Creating
  # fresh destination allocations records the new draw order without changing
  # the provenance of the funding itself.
  defp draw_transfer_allocations(source, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          join: r in Room,
          on: a.room_id == r.id,
          where: r.group_record_id == ^source.id and r.status == "active",
          order_by: [desc: a.allocation_order, desc: a.id]
      )

    Enum.reduce_while(allocations, {amount, []}, fn allocation, {remaining, moved} ->
      drawn = min(allocation.amount_cents, remaining)

      result =
        if drawn == allocation.amount_cents do
          Repo.delete(allocation)
        else
          allocation
          |> RoomAllocation.changeset(%{amount_cents: allocation.amount_cents - drawn})
          |> Repo.update()
        end

      case result do
        {:ok, _allocation} ->
          chunk = %{
            funding_type: allocation.funding_type,
            payment_operation_id: allocation.payment_operation_id,
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: drawn
          }

          left = remaining - drawn
          chunks = [chunk | moved]
          if left == 0, do: {:halt, {0, Enum.reverse(chunks)}}, else: {:cont, {left, chunks}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {0, chunks} -> {:ok, chunks}
      {:error, changeset} -> {:error, changeset}
      _ -> {:error, :invalid_operation}
    end
  end

  defp allocate_transferred_funding(destination, chunks) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      attrs = Map.take(chunk, [:funding_type, :payment_operation_id, :credit_lot_id])

      case allocate_to_rooms(destination, chunk.amount_cents, attrs) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp move_credit_allocation_totals(source, destination, chunks) do
    chunks
    |> Enum.filter(&(&1.funding_type == "credit"))
    |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
    |> Enum.reduce_while(:ok, fn {lot_id, amounts}, :ok ->
      amount = Enum.sum(amounts)
      lot = Repo.get!(CreditLot, lot_id)

      with :ok <- reduce_group_credit_allocation(source.id, lot_id, amount),
           :ok <- add_credit_allocation(destination, lot, amount) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp mark_transferred_payments(chunks) do
    chunks
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn operation_id, :ok ->
      payment = Repo.get_by!(CashPayment, operation_id: operation_id)

      case update_cash_payment(payment, %{transfer_participated: true}) do
        {:ok, _payment} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp moved_amount(chunks, funding_type) do
    chunks
    |> Enum.filter(&(&1.funding_type == funding_type))
    |> sum_field(:amount_cents)
  end

  defp remove_held_cash(_operation_id, 0), do: {:ok, %{}}

  defp remove_held_cash(operation_id, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          where: a.payment_operation_id == ^operation_id and a.funding_type == "cash",
          order_by: [desc: a.allocation_order, desc: a.id]
      )

    Enum.reduce_while(allocations, {amount, %{}}, fn allocation, {remaining, removed_by_group} ->
      removed = min(allocation.amount_cents, remaining)
      group_id = allocation_group_id(allocation)

      result =
        if removed == allocation.amount_cents do
          Repo.delete(allocation)
        else
          allocation
          |> RoomAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
          |> Repo.update()
        end

      case result do
        {:ok, _allocation} ->
          left = remaining - removed
          totals = Map.update(removed_by_group, group_id, removed, &(&1 + removed))
          if left == 0, do: {:halt, {0, totals}}, else: {:cont, {left, totals}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {0, totals} -> {:ok, totals}
      {:error, changeset} -> {:error, changeset}
      _ -> {:error, :invalid_operation}
    end
  end

  defp update_groups_after_cash_removal(
         removals,
         addressed_group,
         addressed_attrs,
         group_adjustments \\ %{}
       ) do
    group_ids =
      removals
      |> Map.keys()
      |> Enum.concat(Map.keys(group_adjustments))
      |> Enum.concat([addressed_group.id])
      |> Enum.uniq()

    Enum.reduce_while(group_ids, {:ok, nil}, fn group_id, {:ok, updated_addressed} ->
      group =
        if group_id == addressed_group.id, do: addressed_group, else: Repo.get!(Group, group_id)

      removed = Map.get(removals, group_id, 0)

      attrs = %{
        deposit_paid_cents: group.deposit_paid_cents - removed,
        cash_paid_cents: group.cash_paid_cents - removed,
        revision: group.revision + 1
      }

      attrs = apply_group_adjustments(group, attrs, Map.get(group_adjustments, group_id, %{}))

      attrs =
        if group_id == addressed_group.id, do: Map.merge(attrs, addressed_attrs), else: attrs

      case update_group(group, attrs) do
        {:ok, updated} ->
          result = if group_id == addressed_group.id, do: updated, else: updated_addressed
          {:cont, {:ok, result}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp apply_group_adjustments(group, attrs, adjustments) do
    Enum.reduce(adjustments, attrs, fn {field, delta}, updated_attrs ->
      Map.put(updated_attrs, field, Map.fetch!(group, field) + delta)
    end)
  end

  defp allocation_group_id(allocation) do
    Repo.one!(from r in Room, where: r.id == ^allocation.room_id, select: r.group_record_id)
  end

  defp settle_cash_allocations(group, allocations, operation, occurred_on, method, refundable?) do
    principal = sum_field(allocations, :amount_cents)
    disposition = cash_disposition(method, refundable?)

    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id, & &1.amount_cents)
    |> Enum.reduce_while(:ok, fn {operation_id, amounts}, :ok ->
      payment = Repo.get_by!(CashPayment, operation_id: operation_id)
      amount = Enum.sum(amounts)
      field = disposition_field(disposition)

      case update_cash_payment(payment, %{field => Map.fetch!(payment, field) + amount}) do
        {:ok, _payment} ->
          case add_cash_settlement(group, operation_id, field, amount) do
            :ok -> {:cont, :ok}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok -> issue_credit_lot(group, allocations, operation, occurred_on, disposition, principal)
      error -> error
    end
  end

  defp add_cash_settlement(group, payment_operation_id, field, amount) do
    settlement =
      Repo.get_by(CashSettlement,
        payment_operation_id: payment_operation_id,
        group_record_id: group.id
      ) || %CashSettlement{payment_operation_id: payment_operation_id, group_record_id: group.id}

    attrs =
      %{
        payment_operation_id: payment_operation_id,
        group_record_id: group.id
      }
      |> Map.put(field, Map.fetch!(settlement, field) + amount)

    settlement |> CashSettlement.changeset(attrs) |> Repo.insert_or_update() |> ok_result()
  end

  defp cash_settlement_adjustments(payment_operation_id) do
    Repo.all(
      from s in CashSettlement,
        where: s.payment_operation_id == ^payment_operation_id
    )
    |> Map.new(fn settlement ->
      {settlement.group_record_id,
       %{
         cash_refunded_cents: -settlement.refunded_cents,
         cash_retained_cents: -settlement.retained_cents,
         cash_converted_to_credit_cents: -settlement.converted_to_credit_cents
       }}
    end)
  end

  defp record_cash_settlement_movement(group, occurred_on, amount, method, refundable?) do
    classification =
      case cash_disposition(method, refundable?) do
        :refunded -> "refunded"
        :retained -> "retained"
        :converted -> "converted_to_credit"
      end

    FinanceReporting.record_cash(
      FinanceReporting.posting(occurred_on),
      group.property_id,
      classification,
      amount
    )
  end

  defp record_removed_cash(removals, occurred_on, classification) do
    posting = FinanceReporting.posting(occurred_on)

    Enum.reduce_while(removals, :ok, fn {group_record_id, amount}, :ok ->
      property_id = Repo.get!(Group, group_record_id).property_id

      case FinanceReporting.record_cash(posting, property_id, classification, amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp record_settlement_chargebacks(adjustments, occurred_on) do
    posting = FinanceReporting.posting(occurred_on)

    Enum.reduce_while(adjustments, :ok, fn {group_record_id, deltas}, :ok ->
      property_id = Repo.get!(Group, group_record_id).property_id

      result =
        Enum.reduce_while(
          [
            {"refunded", deltas.cash_refunded_cents},
            {"retained", deltas.cash_retained_cents},
            {"converted_to_credit", deltas.cash_converted_to_credit_cents}
          ],
          :ok,
          fn {classification, amount}, :ok ->
            case FinanceReporting.record_cash(posting, property_id, classification, amount) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end
        )

      settled = -Enum.sum(Map.values(deltas))

      with :ok <- result,
           :ok <-
             FinanceReporting.record_cash(
               posting,
               property_id,
               "charged_back",
               settled
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp clear_cash_settlements(payment_operation_id) do
    {_count, _rows} =
      Repo.delete_all(
        from s in CashSettlement,
          where: s.payment_operation_id == ^payment_operation_id
      )

    :ok
  end

  defp issue_credit_lot(_group, _allocations, _operation, _on, disposition, _principal)
       when disposition != :converted,
       do: {:ok, 0}

  defp issue_credit_lot(_group, _allocations, _operation, _on, :converted, 0), do: {:ok, 0}

  defp issue_credit_lot(group, allocations, operation, occurred_on, :converted, principal) do
    issued = bonus_value(principal)

    with {:ok, lot} <-
           %CreditLot{}
           |> CreditLot.changeset(%{
             guest_id: group.guest_id,
             source_operation_id: operation["operation_id"],
             remaining_cents: issued,
             expires_on: Date.add(occurred_on, 365),
             unrecovered_clawback_cents: 0
           })
           |> Repo.insert(),
         :ok <- insert_entitlements(lot, allocations) do
      posting = FinanceReporting.posting(occurred_on)

      with :ok <- FinanceReporting.record_credit(posting, "issued", issued),
           :ok <- FinanceReporting.schedule_expiry(lot, posting) do
        {:ok, issued}
      end
    end
  end

  defp insert_entitlements(lot, allocations) do
    contributions =
      allocations
      |> Enum.sort_by(&{&1.allocation_order, &1.id})
      |> Enum.chunk_by(& &1.payment_operation_id)
      |> Enum.map(fn chunk ->
        {hd(chunk).payment_operation_id, sum_field(chunk, :amount_cents)}
      end)

    contributions
    |> Enum.reduce_while({:ok, {0, 0}}, fn {payment_operation_id, principal},
                                           {:ok, {running, previous_value}} ->
      new_running = running + principal
      new_value = bonus_value(new_running)

      result =
        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          issued_cents: new_value - previous_value,
          revoked_cents: 0
        })
        |> Repo.insert()

      case result do
        {:ok, _entitlement} -> {:cont, {:ok, {new_running, new_value}}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, _running} -> :ok
      error -> error
    end
  end

  defp settle_credit_allocations(group, allocations, occurred_on, refundable?) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce_while(:ok, fn {lot_id, room_allocations}, :ok ->
      amount = sum_field(room_allocations, :amount_cents)
      lot = Repo.get!(CreditLot, lot_id)

      with :ok <- maybe_restore_credit(lot, amount, occurred_on, refundable?),
           :ok <- reduce_group_credit_allocation(group.id, lot_id, amount),
           :ok <- delete_allocations(room_allocations) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp maybe_restore_credit(_lot, amount, occurred_on, false) do
    FinanceReporting.record_credit(
      FinanceReporting.posting(occurred_on),
      "consumed",
      amount
    )
  end

  defp maybe_restore_credit(lot, amount, occurred_on, true) do
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    restorable = amount - absorbed
    available = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: restorable

    posting = FinanceReporting.posting(occurred_on)

    reportable_available =
      if posting && Date.before?(lot.expires_on, posting.date), do: 0, else: restorable

    with {:ok, _lot} <-
           lot
           |> CreditLot.changeset(%{
             remaining_cents: lot.remaining_cents + available,
             unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
           })
           |> Repo.update(),
         :ok <- FinanceReporting.record_credit(posting, "absorbed", absorbed),
         :ok <-
           FinanceReporting.record_credit(
             posting,
             "expired",
             restorable - reportable_available
           ),
         :ok <-
           FinanceReporting.adjust_scheduled_expiry(lot, posting, reportable_available) do
      :ok
    end
  end

  defp reduce_group_credit_allocation(group_id, lot_id, amount) do
    allocation = Repo.get_by!(CreditAllocation, group_record_id: group_id, credit_lot_id: lot_id)

    if allocation.amount_cents == amount do
      Repo.delete(allocation) |> ok_result()
    else
      allocation
      |> CreditAllocation.changeset(%{amount_cents: allocation.amount_cents - amount})
      |> Repo.update()
      |> ok_result()
    end
  end

  defp revoke_credit_entitlements(payment_operation_id, occurred_on) do
    posting = FinanceReporting.posting(occurred_on)

    entitlements =
      Repo.all(
        from e in CreditEntitlement,
          where: e.payment_operation_id == ^payment_operation_id,
          order_by: e.id
      )

    Enum.reduce_while(entitlements, :ok, fn entitlement, :ok ->
      amount = entitlement.issued_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, amount)
      unrecovered = amount - removed

      reportable_revocation =
        if posting && Date.before?(lot.expires_on, posting.date), do: 0, else: removed

      with {:ok, _lot} <-
             lot
             |> CreditLot.changeset(%{
               remaining_cents: lot.remaining_cents - removed,
               unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
             })
             |> Repo.update(),
           {:ok, _entitlement} <-
             entitlement
             |> CreditEntitlement.changeset(%{revoked_cents: entitlement.issued_cents})
             |> Repo.update(),
           :ok <- FinanceReporting.record_credit(posting, "revoked", reportable_revocation),
           :ok <-
             FinanceReporting.adjust_scheduled_expiry(lot, posting, -reportable_revocation) do
        {:cont, :ok}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp add_credit_allocation(group, lot, amount) do
    case Repo.get_by(CreditAllocation, group_record_id: group.id, credit_lot_id: lot.id) do
      nil ->
        %CreditAllocation{}
        |> CreditAllocation.changeset(%{
          group_record_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: amount
        })
        |> Repo.insert()
        |> ok_result()

      allocation ->
        allocation
        |> CreditAllocation.changeset(%{amount_cents: allocation.amount_cents + amount})
        |> Repo.update()
        |> ok_result()
    end
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp enough_credit(lots, amount) do
    if sum_field(lots, :remaining_cents) >= amount,
      do: :ok,
      else: {:error, :insufficient_credit}
  end

  defp allocations(rooms, funding_type) do
    rooms
    |> Enum.flat_map(& &1.allocations)
    |> Enum.filter(&(&1.funding_type == funding_type))
    |> Enum.sort_by(&{&1.allocation_order, &1.id})
  end

  defp load_rooms(group_id, room_ids) do
    Repo.all(
      from r in Room,
        where: r.group_record_id == ^group_id and r.room_id in ^room_ids,
        order_by: r.position,
        preload: [:allocations]
    )
  end

  defp cancel_room_records(rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case room |> Room.changeset(%{status: "cancelled"}) |> Repo.update() do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp delete_allocations(allocations) do
    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      case Repo.delete(allocation) do
        {:ok, _allocation} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp active_rooms?(group_id),
    do:
      Repo.exists?(from r in Room, where: r.group_record_id == ^group_id and r.status == "active")

  defp held_cents(operation_id) do
    Repo.one(
      from a in RoomAllocation,
        where: a.payment_operation_id == ^operation_id and a.funding_type == "cash",
        select: coalesce(sum(a.amount_cents), 0)
    ) || 0
  end

  defp render_payment(payment) do
    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: Repo.get!(Group, payment.group_record_id).group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: held_cents(payment.operation_id),
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }

    if payment.transfer_participated do
      Map.put(statement, :held_by_group, held_cash_by_group(payment.operation_id))
    else
      statement
    end
  end

  defp held_cash_by_group(operation_id) do
    Repo.all(
      from a in RoomAllocation,
        join: r in Room,
        on: a.room_id == r.id,
        join: g in Group,
        on: r.group_record_id == g.id,
        where: a.payment_operation_id == ^operation_id and a.funding_type == "cash",
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp selected_room_ids(operation) do
    case Map.fetch(operation, "room_ids") do
      {:ok, ids} when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) and Enum.uniq(ids) == ids,
          do: {:ok, ids},
          else: {:error, :invalid_rooms}

      _ ->
        {:error, :invalid_rooms}
    end
  end

  defp validate_selected_rooms(group, ids) do
    ordered =
      Repo.all(
        from r in Room,
          where: r.group_record_id == ^group.id and r.room_id in ^ids and r.status == "active",
          order_by: r.position,
          select: r.room_id
      )

    if length(ordered) == length(ids), do: {:ok, ordered}, else: {:error, :invalid_rooms}
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _ -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method_available(_method, _refundable?), do: :ok

  defp cash_disposition("hotel_credit", true), do: :converted
  defp cash_disposition("cash", true), do: :refunded
  defp cash_disposition(_method, false), do: :retained

  defp disposition_field(:converted), do: :converted_to_credit_cents
  defp disposition_field(:refunded), do: :refunded_cents
  defp disposition_field(:retained), do: :retained_cents

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @new_flexible_policy_date), do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: nil} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp group_policy_version(group), do: group.policy_version

  defp refundable_until(group) do
    case group_policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp transaction(fun) do
    if Repo.in_transaction?() do
      domain_savepoint(fun)
    else
      transaction = fn ->
        case catch_domain_rollback(fun) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      case Repo.transaction(transaction, mode: :immediate) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> normalize_transaction_error(reason)
      end
    end
  end

  defp domain_savepoint(fun) do
    Repo.query!("SAVEPOINT group_stay_domain_operation")

    case catch_domain_rollback(fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT group_stay_domain_operation")
        normalize_transaction_error(reason)
    end
  after
    Repo.query!("RELEASE SAVEPOINT group_stay_domain_operation")
  end

  defp catch_domain_rollback(fun) do
    {:ok, fun.()}
  catch
    :throw, {__MODULE__, :domain_rollback, reason} -> {:error, reason}
  end

  defp normalize_transaction_error({code, details}), do: {:error, code, details}
  defp normalize_transaction_error(code), do: {:error, code}
  defp rollback(reason), do: throw({__MODULE__, :domain_rollback, reason})

  defp insert_group(attrs), do: %Group{} |> Group.create_changeset(attrs) |> Repo.insert()

  defp insert_cash_payment(group, operation_id, amount) do
    %CashPayment{}
    |> CashPayment.changeset(%{
      operation_id: operation_id,
      group_record_id: group.id,
      recorded_cents: amount,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    })
    |> Repo.insert()
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {room, position}, :ok ->
      attrs = Map.merge(room, %{group_record_id: group.id, position: position})

      case %Room{} |> Room.changeset(attrs) |> Repo.insert() do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp update_group(group, attrs), do: group |> Group.update_changeset(attrs) |> Repo.update()

  defp update_cash_payment(payment, attrs),
    do: payment |> CashPayment.changeset(attrs) |> Repo.update()

  defp check_revision(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        {:error, :stale_revision,
         %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}

      {:ok, _invalid} ->
        {:error, :invalid_operation}
    end
  end

  defp check_transfer_revision!(group, operation, key) do
    case Map.fetch(operation, key) do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        rollback(
          {:stale_revision,
           %{
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }}
        )

      {:ok, _invalid} ->
        rollback(:invalid_operation)
    end
  end

  defp valid_operation_id(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp valid_operation_id(_), do: {:error, :invalid_operation}

  defp required_identifier(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  defp required_date(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_operation}
        end

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp reporting_date(operation) do
    case Map.fetch(operation, "starts_on") do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_reporting_date}
        end

      _ ->
        {:error, :invalid_reporting_date}
    end
  end

  defp domain_date(operation, key) do
    case Map.fetch(operation, key) do
      :error ->
        {:error, :invalid_operation}

      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_stay}
        end

      {:ok, _} ->
        {:error, :invalid_stay}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.before?(arrival_on, departure_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival(arrival_on, occurred_on) do
    if Date.after?(arrival_on, occurred_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp reschedule_date(operation) do
    case Map.fetch(operation, "new_arrival_on") do
      :error -> {:error, :invalid_operation}
      {:ok, _} -> domain_date(operation, "new_arrival_on")
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, :invalid_operation}
      {:ok, rate_plan} when rate_plan in @rate_plans -> {:ok, rate_plan}
      {:ok, _} -> {:error, :invalid_rate_plan}
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error -> {:error, :invalid_operation}
      {:ok, rooms} when is_list(rooms) and rooms != [] -> validate_rooms(rooms)
      {:ok, _} -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(rooms) do
    parsed =
      Enum.reduce_while(rooms, [], fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}, acc
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate} | acc]}

        _, _acc ->
          {:halt, :invalid}
      end)

    case parsed do
      :invalid ->
        {:error, :invalid_rooms}

      parsed ->
        parsed = Enum.reverse(parsed)
        ids = Enum.map(parsed, & &1.room_id)
        if Enum.uniq(ids) == ids, do: {:ok, parsed}, else: {:error, :invalid_rooms}
    end
  end

  defp price_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging = room.nightly_rate_cents * nights
      due = if rate_plan == "flexible", do: round_percentage(lodging, 20), else: lodging

      Map.merge(room, %{
        status: "active",
        lodging_total_cents: lodging,
        deposit_due_cents: due
      })
    end)
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error -> {:error, :invalid_operation}
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :invalid_amount}
    end
  end

  defp reduction_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp transfer_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp reducible(held) when held > 0, do: :ok
  defp reducible(_held), do: {:error, :payment_not_reducible}

  defp chargeable(%CashPayment{charged_back_cents: 0}, remaining) when remaining > 0, do: :ok
  defp chargeable(_payment, _remaining), do: {:error, :payment_not_chargeable}

  defp does_not_exceed(amount, outstanding) when amount <= outstanding, do: :ok
  defp does_not_exceed(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp reduction_does_not_exceed(amount, held) when amount <= held, do: :ok
  defp reduction_does_not_exceed(_amount, _held), do: {:error, :reduction_exceeds_held_cash}

  defp valid_transfer_parties(%Group{id: id}, %Group{id: id}), do: {:error, :invalid_transfer}

  defp valid_transfer_parties(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok
  defp valid_transfer_parties(_source, _destination), do: {:error, :invalid_transfer}

  defp transfer_group_active(%Group{status: "active"}), do: :ok

  defp transfer_group_active(group),
    do: {:error, :group_not_active, %{group_id: group.group_id}}

  defp transfer_does_not_exceed_held(amount, held) when amount <= held, do: :ok

  defp transfer_does_not_exceed_held(_amount, _held),
    do: {:error, :transfer_exceeds_held_funding}

  defp transfer_does_not_exceed_outstanding(amount, outstanding) when amount <= outstanding,
    do: :ok

  defp transfer_does_not_exceed_outstanding(_amount, _outstanding),
    do: {:error, :transfer_exceeds_outstanding}

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp sum_field(items, field), do: Enum.sum(Enum.map(items, &Map.fetch!(&1, field)))
  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)
  defp bonus_value(principal), do: principal + round_percentage(principal, 10)

  defp ok_result({:ok, _record}), do: :ok
  defp ok_result({:error, changeset}), do: {:error, changeset}

  defp render_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &render_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp render_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      lodging_total_cents: if(room.status == "active", do: room.lodging_total_cents, else: 0),
      deposit_due_cents: if(room.status == "active", do: room.deposit_due_cents, else: 0),
      cash_paid_cents: allocation_total(room, "cash"),
      credit_paid_cents: allocation_total(room, "credit")
    }
  end

  defp allocation_total(%Room{status: "cancelled"}, _type), do: 0

  defp allocation_total(room, type) do
    room.allocations
    |> Enum.filter(&(&1.funding_type == type))
    |> sum_field(:amount_cents)
  end

  defp rejection(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end
end
