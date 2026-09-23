defmodule GroupStay.Groups do
  @moduledoc "Operations and read models for group reservations."

  import Ecto.Query

  alias GroupStay.Groups.{Group, OperationRecord, Room}

  alias GroupStay.Ledger.{
    CashPayment,
    CreditAllocation,
    CreditLot,
    CreditLotEntitlement,
    Entry,
    FinanceCashMovement,
    FinanceCreditEvent,
    FinanceCreditOpening,
    FinanceReporting,
    FundingAllocationOrder,
    CashPaymentSettlement,
    RoomCashAllocation
  }

  alias GroupStay.Repo

  @max_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group_id,
              order_by: [asc: room.position, asc: room.id]
          )

        {group, rooms}
    end
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      nil ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil -> :not_found
          _record -> :not_reconcilable
        end

      payment ->
        statement = %{
          payment_operation_id: payment.payment_operation_id,
          original_group_id: payment.group_id,
          recorded_cents: payment.recorded_cents,
          held_cents: payment.held_cents,
          refunded_cents: payment.refunded_cents,
          retained_cents: payment.retained_cents,
          converted_to_credit_cents: payment.converted_to_credit_cents,
          reduced_cents: payment.reduced_cents,
          charged_back_cents: payment.charged_back_cents
        }

        if payment.transferred do
          Map.put(statement, :held_by_group, held_cash_by_group(payment.payment_operation_id))
        else
          statement
        end
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in RoomCashAllocation,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
        where: allocation.payment_operation_id == ^payment_operation_id,
        where: room.status == "active",
        group_by: allocation.group_id,
        order_by: [asc: allocation.group_id],
        select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount || 0} end)
  end

  def ledger_totals(on \\ Date.utc_today()) do
    totals =
      Repo.all(
        from entry in Entry,
          select: {entry.kind, entry.amount_cents}
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    received = Map.get(totals, "payment", 0) || 0
    refunded = (Map.get(totals, "refund", 0) || 0) - (Map.get(totals, "refund_reversal", 0) || 0)

    retained =
      (Map.get(totals, "retention", 0) || 0) - (Map.get(totals, "retention_reversal", 0) || 0)

    converted =
      (Map.get(totals, "cash_to_credit", 0) || 0) -
        (Map.get(totals, "cash_to_credit_reversal", 0) || 0)

    reduced = Map.get(totals, "cash_reduced", 0) || 0
    charged_back = Map.get(totals, "cash_charged_back", 0) || 0

    available_credit = available_credit_total(on)

    applied_credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: allocation.group_id == group.group_id,
          join: lot in CreditLot,
          on: allocation.credit_lot_id == lot.id,
          where: group.status == "active",
          where: lot.issued_on <= ^on,
          select: sum(allocation.amount_cents)
      ) || 0

    shortfall = credit_shortfall_total()

    %{
      cash_held_cents: received - refunded - retained - converted - reduced - charged_back,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: available_credit + applied_credit,
      credit_shortfall_cents: shortfall
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  def daily_finance_report(date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        nil

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          nil
        else
          %{
            date: date,
            status: "open",
            cash: daily_cash_report(reporting, date),
            credit: daily_credit_report(reporting, date)
          }
        end
    end
  end

  def cancellation_policy(%Group{} = group) do
    %{
      policy_version: group.policy_version,
      refundable_until: refundable_until(group.policy_version, group.arrival_on)
    }
  end

  defp daily_cash_report(reporting, date) do
    movements =
      Repo.all(
        from movement in FinanceCashMovement,
          where: movement.posting_on <= ^date,
          order_by: [asc: movement.id]
      )

    properties =
      (Map.keys(reporting.opening_cash_by_property || %{}) ++
         Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening_balance =
        Map.get(reporting.opening_cash_by_property || %{}, property_id, 0) +
          (movements
           |> Enum.filter(
             &(&1.property_id == property_id and Date.compare(&1.posting_on, date) == :lt)
           )
           |> Enum.reduce(0, &(&2 + cash_movement_effect(&1.classification, &1.amount_cents))))

      daily_movements =
        movements
        |> Enum.filter(&(&1.property_id == property_id and &1.posting_on == date))
        |> Enum.reduce(empty_cash_movements(), fn movement, totals ->
          Map.update!(
            totals,
            String.to_existing_atom(movement.classification),
            &(&1 + movement.amount_cents)
          )
        end)

      closing_balance =
        opening_balance +
          Enum.reduce(daily_movements, 0, fn {kind, amount}, sum ->
            sum + cash_movement_effect(Atom.to_string(kind), amount)
          end)

      if opening_balance == 0 and closing_balance == 0 and
           Enum.all?(daily_movements, fn {_kind, amount} -> amount == 0 end) do
        []
      else
        [
          %{
            property_id: property_id,
            opening_held_cents: opening_balance,
            movements: daily_movements,
            closing_held_cents: closing_balance
          }
        ]
      end
    end)
  end

  defp daily_credit_report(reporting, date) do
    openings = Repo.all(FinanceCreditOpening)

    event_rows =
      Repo.all(
        from event in FinanceCreditEvent,
          where: event.posting_on <= ^date,
          order_by: [asc: event.posting_on, asc: event.id]
      )

    lot_ids =
      Enum.uniq(
        Enum.map(openings, & &1.credit_lot_id) ++ Enum.map(event_rows, & &1.credit_lot_id)
      )

    expirations =
      if lot_ids == [] do
        %{}
      else
        Repo.all(
          from lot in CreditLot, where: lot.id in ^lot_ids, select: {lot.id, lot.expires_on}
        )
        |> Map.new()
      end

    initial_state =
      Map.new(openings, fn opening ->
        available =
          if Date.compare(opening.expires_on, reporting.starts_on) == :lt,
            do: 0,
            else: opening.available_cents

        {opening.credit_lot_id,
         %{
           available: available,
           applied: opening.applied_cents,
           expires_on: opening.expires_on
         }}
      end)

    initial_state =
      Enum.reduce(expirations, initial_state, fn {lot_id, expires_on}, state ->
        Map.put_new(state, lot_id, %{available: 0, applied: 0, expires_on: expires_on})
      end)

    event_days = Enum.map(event_rows, & &1.posting_on)

    expiry_days =
      openings
      |> Enum.map(&{&1.credit_lot_id, &1.expires_on})
      |> Kernel.++(Enum.map(expirations, fn {lot_id, expires_on} -> {lot_id, expires_on} end))
      |> Enum.map(fn {_lot_id, expires_on} -> Date.add(expires_on, 1) end)
      |> Enum.filter(
        &(Date.compare(&1, reporting.starts_on) != :lt and Date.compare(&1, date) != :gt)
      )

    days =
      (event_days ++ expiry_days ++ [date])
      |> Enum.filter(&(Date.compare(&1, reporting.starts_on) != :lt))
      |> Enum.uniq()
      |> Enum.sort_by(&Date.to_gregorian_days/1)

    events_by_day = Enum.group_by(event_rows, & &1.posting_on)

    {opening_liability, final_state, daily_movements} =
      Enum.reduce(days, {nil, initial_state, empty_credit_movements()}, fn day,
                                                                           {opening, state,
                                                                            totals} ->
        before_day = if day == date, do: credit_liability(state), else: opening
        {state, expired} = expire_available_credit(state, day)

        totals =
          if day == date, do: Map.update!(totals, :expired_cents, &(&1 + expired)), else: totals

        {state, totals} =
          Enum.reduce(Map.get(events_by_day, day, []), {state, totals}, fn event,
                                                                           {current, day_totals} ->
            apply_credit_finance_event(current, day_totals, event, day == date, day)
          end)

        {before_day, state, totals}
      end)

    %{
      opening_liability_cents: opening_liability || reporting.opening_credit_cents,
      movements: daily_movements,
      closing_liability_cents: credit_liability(final_state)
    }
  end

  defp apply_credit_finance_event(state, totals, event, include_movement?, posting_on) do
    current = Map.get(state, event.credit_lot_id, %{available: 0, applied: 0, expires_on: nil})
    amount = event.amount_cents

    {next, movements} =
      case event.kind do
        "issued" ->
          if current.expires_on && Date.compare(current.expires_on, posting_on) == :lt do
            {current, [{:issued_cents, amount}, {:expired_cents, amount}]}
          else
            {%{current | available: current.available + amount}, [{:issued_cents, amount}]}
          end

        "apply" ->
          {%{current | available: current.available - amount, applied: current.applied + amount},
           []}

        "restore" ->
          if current.expires_on && Date.compare(current.expires_on, posting_on) == :lt do
            {%{current | applied: current.applied - amount}, [{:expired_cents, amount}]}
          else
            {%{
               current
               | available: current.available + amount,
                 applied: current.applied - amount
             }, []}
          end

        "consume" ->
          {%{current | applied: current.applied - amount}, [{:consumed_cents, amount}]}

        "revoke" ->
          revoked = min(max(current.available, 0), amount)
          {%{current | available: current.available - revoked}, [{:revoked_cents, revoked}]}

        "expired" ->
          {%{current | applied: current.applied - amount}, [{:expired_cents, amount}]}

        "absorbed" ->
          {%{current | applied: current.applied - amount}, [{:absorbed_cents, amount}]}
      end

    state = Map.put(state, event.credit_lot_id, next)

    totals =
      if include_movement? do
        Enum.reduce(movements, totals, fn {field, value}, acc ->
          Map.update!(acc, field, &(&1 + value))
        end)
      else
        totals
      end

    {state, totals}
  end

  defp expire_available_credit(state, day) do
    Enum.reduce(state, {state, 0}, fn {lot_id, lot}, {current_state, expired_total} ->
      if (lot.expires_on && Date.add(lot.expires_on, 1) == day) and lot.available > 0 do
        updated = %{lot | available: 0}
        {Map.put(current_state, lot_id, updated), expired_total + lot.available}
      else
        {current_state, expired_total}
      end
    end)
  end

  defp credit_liability(state) do
    Enum.reduce(state, 0, fn {_lot_id, lot}, total -> total + lot.available + lot.applied end)
  end

  defp empty_cash_movements do
    %{
      received_cents: 0,
      transferred_in_cents: 0,
      transferred_out_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp empty_credit_movements do
    %{
      issued_cents: 0,
      expired_cents: 0,
      consumed_cents: 0,
      revoked_cents: 0,
      absorbed_cents: 0
    }
  end

  defp cash_movement_effect("received_cents", amount), do: amount
  defp cash_movement_effect("transferred_in_cents", amount), do: amount
  defp cash_movement_effect("transferred_out_cents", amount), do: -amount
  defp cash_movement_effect("refunded_cents", amount), do: -amount
  defp cash_movement_effect("retained_cents", amount), do: -amount
  defp cash_movement_effect("converted_to_credit_cents", amount), do: -amount
  defp cash_movement_effect("reduced_cents", amount), do: -amount
  defp cash_movement_effect("charged_back_cents", amount), do: -amount
  defp cash_movement_effect(_classification, _amount), do: 0

  defp apply_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation_id = Map.get(operation, "operation_id")

    # Serialize the idempotency check and its domain effects against concurrent retries.
    {:ok, result} =
      Repo.transaction(fn -> process_idempotent_operation(operation, operation_id) end,
        mode: :immediate
      )

    result
  end

  defp process_idempotent_operation(operation, operation_id) do
    if valid_identifier?(operation_id) do
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil ->
          result = operation |> run_domain_operation() |> json_value()

          Repo.insert!(
            OperationRecord.changeset(%OperationRecord{}, %{
              operation_id: operation_id,
              operation_type: operation_type(operation),
              submission: operation,
              result: result
            })
          )

          result

        %OperationRecord{submission: ^operation, result: result} ->
          result

        %OperationRecord{} ->
          rejected(operation_id, "operation_id_conflict") |> json_value()
      end
    else
      operation |> run_domain_operation() |> json_value()
    end
  end

  defp run_domain_operation(operation) do
    Repo.query!("SAVEPOINT group_stay_operation")

    # A handled rejection rolls back only domain work so its result can still be recorded.
    result =
      try do
        apply_domain_operation(operation)
      catch
        {:handled_rejection, result} ->
          Repo.query!("ROLLBACK TO SAVEPOINT group_stay_operation")
          result
      end

    Repo.query!("RELEASE SAVEPOINT group_stay_operation")
    result
  end

  defp apply_domain_operation(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      case Map.get(operation, "type") do
        "open_group" -> apply_open_group(operation)
        "start_finance_reporting" -> apply_start_finance_reporting(operation)
        "record_cash_payment" -> apply_existing_group_operation(operation, :payment)
        "apply_hotel_credit" -> apply_existing_group_operation(operation, :credit)
        "reschedule_group" -> apply_existing_group_operation(operation, :reschedule)
        "cancel_group" -> apply_existing_group_operation(operation, :cancel)
        "cancel_rooms" -> apply_existing_group_operation(operation, :cancel_rooms)
        "transfer_deposit" -> apply_transfer_deposit(operation)
        "reduce_cash_payment" -> apply_cash_adjustment(operation, :reduce)
        "charge_back_payment" -> apply_cash_adjustment(operation, :charge_back)
        _ -> rejected(operation_id, "invalid_operation")
      end

    if Map.get(result, :status) == "rejected" do
      result
    else
      Map.merge(result, %{status: "applied", operation_id: operation_id})
    end
  end

  defp apply_start_finance_reporting(operation) do
    operation_id = Map.get(operation, "operation_id")

    with {:ok, starts_on} <- parse_date(Map.get(operation, "starts_on")) do
      cond do
        not valid_identifier?(operation_id) ->
          rejected(operation_id, "invalid_operation")

        Repo.get(FinanceReporting, 1) != nil ->
          rejected(operation_id, "reporting_already_started")

        true ->
          start_finance_reporting!(starts_on)
          %{starts_on: starts_on}
      end
    else
      :error -> rejected(operation_id, "invalid_reporting_date")
    end
  end

  defp start_finance_reporting!(starts_on) do
    opening_cash =
      Repo.all(
        from allocation in RoomCashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: room.status == "active" and group.status == "active",
          group_by: group.property_id,
          select: {group.property_id, sum(allocation.amount_cents)}
      )
      |> Map.new(fn {property_id, amount} -> {property_id, amount || 0} end)

    applied_by_lot =
      Repo.all(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new(fn {lot_id, amount} -> {lot_id, amount || 0} end)

    lot_openings =
      Repo.all(CreditLot)
      |> Enum.map(fn lot ->
        available =
          if Date.compare(lot.expires_on, starts_on) == :lt,
            do: 0,
            else: lot.remaining_cents

        applied = Map.get(applied_by_lot, lot.id, 0)

        %{
          credit_lot_id: lot.id,
          available_cents: available,
          applied_cents: applied,
          expires_on: lot.expires_on
        }
      end)
      |> Enum.filter(&(&1.available_cents > 0 or &1.applied_cents > 0))

    opening_credit =
      Enum.reduce(lot_openings, 0, &(&1.available_cents + &1.applied_cents + &2))

    Repo.insert!(
      FinanceReporting.changeset(%FinanceReporting{}, %{
        id: 1,
        starts_on: starts_on,
        opening_cash_by_property: opening_cash,
        opening_credit_cents: opening_credit
      })
    )

    Enum.each(lot_openings, fn attrs ->
      Repo.insert!(FinanceCreditOpening.changeset(%FinanceCreditOpening{}, attrs))
    end)
  end

  defp report_posting_date(occurred_on) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        nil

      reporting ->
        if Date.compare(occurred_on, reporting.starts_on) == :lt,
          do: reporting.starts_on,
          else: occurred_on
    end
  end

  defp record_cash_report_movement(occurred_on, property_id, classification, amount)
       when is_integer(amount) and amount != 0 do
    case report_posting_date(occurred_on) do
      nil ->
        :ok

      posting_on ->
        Repo.insert!(
          FinanceCashMovement.changeset(%FinanceCashMovement{}, %{
            posting_on: posting_on,
            property_id: property_id,
            classification: Atom.to_string(classification),
            amount_cents: amount
          })
        )
    end
  end

  defp record_cash_report_movement(_occurred_on, _property_id, _classification, _amount), do: :ok

  defp record_credit_report_event(occurred_on, lot_id, kind, amount)
       when is_integer(amount) and amount > 0 do
    case report_posting_date(occurred_on) do
      nil ->
        :ok

      posting_on ->
        Repo.insert!(
          FinanceCreditEvent.changeset(%FinanceCreditEvent{}, %{
            posting_on: posting_on,
            credit_lot_id: lot_id,
            kind: kind,
            amount_cents: amount
          })
        )
    end
  end

  defp record_credit_report_event(_occurred_on, _lot_id, _kind, _amount), do: :ok

  defp apply_transfer_deposit(operation) do
    operation_id = Map.get(operation, "operation_id")
    source_group_id = Map.get(operation, "source_group_id")
    destination_group_id = Map.get(operation, "destination_group_id")

    unless valid_identifier?(operation_id) and valid_identifier?(source_group_id) and
             valid_identifier?(destination_group_id) do
      reject!({:rejected, rejected(operation_id, "invalid_operation")})
    end

    case Repo.get(Group, source_group_id) do
      nil ->
        reject!(
          {:rejected, rejected(operation_id, "group_not_found", %{group_id: source_group_id})}
        )

      source_group ->
        case Repo.get(Group, destination_group_id) do
          nil ->
            reject!(
              {:rejected,
               rejected(operation_id, "group_not_found", %{group_id: destination_group_id})}
            )

          destination_group ->
            check_transfer_revision!(
              operation_id,
              source_group,
              Map.get(operation, "expected_revision"),
              Map.has_key?(operation, "expected_revision")
            )

            check_transfer_revision!(
              operation_id,
              destination_group,
              Map.get(operation, "destination_expected_revision"),
              Map.has_key?(operation, "destination_expected_revision")
            )

            transfer_between_groups(operation, source_group, destination_group)
        end
    end
  end

  defp check_transfer_revision!(_operation_id, _group, _expected, false), do: :ok

  defp check_transfer_revision!(operation_id, group, expected, true) do
    if expected !== group.revision do
      reject!(
        {:rejected,
         rejected(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         })}
      )
    end
  end

  defp transfer_between_groups(operation, source_group, destination_group) do
    operation_id = operation["operation_id"]

    cond do
      source_group.status != "active" ->
        reject!(
          {:rejected,
           rejected(operation_id, "group_not_active", %{group_id: source_group.group_id})}
        )

      destination_group.status != "active" ->
        reject!(
          {:rejected,
           rejected(operation_id, "group_not_active", %{group_id: destination_group.group_id})}
        )

      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        reject!({:rejected, rejected(operation_id, "invalid_transfer")})

      not Map.has_key?(operation, "amount_cents") ->
        reject!({:rejected, rejected(operation_id, "invalid_operation")})

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        reject!({:rejected, rejected(operation_id, "invalid_amount")})

      true ->
        amount = operation["amount_cents"]
        source_allocations = held_funding_allocations(source_group.group_id)

        held =
          Enum.reduce(source_allocations, 0, fn {_order, _kind, allocation}, total ->
            total + allocation.amount_cents
          end)

        if amount > held do
          reject!({:rejected, rejected(operation_id, "transfer_exceeds_held_funding")})
        end

        destination_rooms = active_rooms(destination_group.group_id)
        destination_outstanding = outstanding_for_rooms(destination_rooms)

        if amount > destination_outstanding do
          reject!({:rejected, rejected(operation_id, "transfer_exceeds_outstanding")})
        end

        transferred_cash = transferred_cash_amount(source_allocations, amount)

        move_held_funding(
          source_allocations,
          source_group,
          destination_group,
          destination_rooms,
          amount
        )

        if transferred_cash > 0 do
          transfer_date = accounting_date(operation)

          record_cash_report_movement(
            transfer_date,
            source_group.property_id,
            :transferred_out_cents,
            transferred_cash
          )

          record_cash_report_movement(
            transfer_date,
            destination_group.property_id,
            :transferred_in_cents,
            transferred_cash
          )
        end

        source_updated = update_group_totals(source_group, source_group.revision + 1)

        destination_updated =
          update_group_totals(destination_group, destination_group.revision + 1)

        %{
          source_group_id: source_group.group_id,
          destination_group_id: destination_group.group_id,
          amount_cents: amount,
          source_outstanding_deposit_cents:
            source_updated.deposit_due_cents - source_updated.deposit_paid_cents,
          destination_outstanding_deposit_cents:
            destination_updated.deposit_due_cents - destination_updated.deposit_paid_cents,
          source_revision: source_updated.revision,
          destination_revision: destination_updated.revision
        }
    end
  end

  defp transferred_cash_amount(allocations, amount) do
    {_remaining, cash_amount} =
      Enum.reduce_while(allocations, {amount, 0}, fn {_order, kind, allocation},
                                                     {remaining, cash} ->
        moved = min(remaining, allocation.amount_cents)
        next_cash = if kind == :cash, do: cash + moved, else: cash
        next_remaining = remaining - moved

        if next_remaining == 0,
          do: {:halt, {0, next_cash}},
          else: {:cont, {next_remaining, next_cash}}
      end)

    cash_amount
  end

  defp held_funding_allocations(group_id) do
    cash =
      Repo.all(
        from allocation in RoomCashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: allocation.group_id == ^group_id,
          where: room.status == "active",
          order_by: [desc: allocation.allocation_order_id, desc: allocation.id]
      )
      |> Enum.map(&{&1.allocation_order_id, :cash, &1})

    credit =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: allocation.group_id == ^group_id,
          where: room.status == "active",
          order_by: [desc: allocation.allocation_order_id, desc: allocation.id]
      )
      |> Enum.map(&{&1.allocation_order_id, :credit, &1})

    Enum.sort_by(
      cash ++ credit,
      fn {order, _kind, allocation} -> {order, allocation.id} end,
      :desc
    )
  end

  defp move_held_funding(allocations, source_group, destination_group, destination_rooms, amount) do
    {_remaining, _destination_rooms, transferred_payment_ids} =
      Enum.reduce_while(allocations, {amount, destination_rooms, MapSet.new()}, fn
        _allocation, {0, rooms, touched_payments} ->
          {:halt, {0, rooms, touched_payments}}

        {_order, kind, allocation}, {remaining, rooms, touched_payments} ->
          moved = min(remaining, allocation.amount_cents)
          update_source_allocation!(kind, allocation, moved)
          decrement_room_funding!(source_group.group_id, allocation.room_id, kind, moved)

          {rooms, _allocated} =
            allocate_transferred_funding(
              rooms,
              destination_group,
              kind,
              allocation,
              moved
            )

          touched_payments =
            if kind == :cash and moved > 0 and not is_nil(allocation.payment_operation_id) do
              MapSet.put(touched_payments, allocation.payment_operation_id)
            else
              touched_payments
            end

          next = remaining - moved

          if next == 0,
            do: {:halt, {0, rooms, touched_payments}},
            else: {:cont, {next, rooms, touched_payments}}
      end)

    Enum.each(transferred_payment_ids, fn payment_id ->
      CashPayment
      |> Repo.get!(payment_id)
      |> Ecto.Changeset.change(transferred: true)
      |> Repo.update!()
    end)

    :ok
  end

  defp update_source_allocation!(:cash, allocation, moved) do
    if moved == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - moved)
      )
    end
  end

  defp update_source_allocation!(:credit, allocation, moved) do
    if moved == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - moved)
      )
    end
  end

  defp decrement_room_funding!(group_id, room_id, kind, amount) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    fields =
      case kind do
        :cash ->
          [
            deposit_paid_cents: room.deposit_paid_cents - amount,
            cash_paid_cents: room.cash_paid_cents - amount
          ]

        :credit ->
          [
            deposit_paid_cents: room.deposit_paid_cents - amount,
            credit_paid_cents: room.credit_paid_cents - amount
          ]
      end

    Repo.update!(Ecto.Changeset.change(room, fields))
  end

  defp allocate_transferred_funding(rooms, destination_group, kind, allocation, amount) do
    Enum.reduce_while(rooms, {rooms, amount}, fn room, {current_rooms, remaining} ->
      available = max(room.deposit_due_cents - room.deposit_paid_cents, 0)
      moved = min(available, remaining)

      current_rooms =
        if moved > 0 do
          fields =
            case kind do
              :cash ->
                [
                  deposit_paid_cents: room.deposit_paid_cents + moved,
                  cash_paid_cents: room.cash_paid_cents + moved
                ]

              :credit ->
                [
                  deposit_paid_cents: room.deposit_paid_cents + moved,
                  credit_paid_cents: room.credit_paid_cents + moved
                ]
            end

          updated_room = Repo.update!(Ecto.Changeset.change(room, fields))
          insert_transferred_allocation!(kind, destination_group, updated_room, allocation, moved)

          Enum.map(current_rooms, &if(&1.id == updated_room.id, do: updated_room, else: &1))
        else
          current_rooms
        end

      next = remaining - moved
      if next == 0, do: {:halt, {current_rooms, 0}}, else: {:cont, {current_rooms, next}}
    end)
  end

  defp insert_transferred_allocation!(:cash, group, room, allocation, amount) do
    order = next_allocation_order()

    Repo.insert!(
      RoomCashAllocation.changeset(%RoomCashAllocation{}, %{
        group_id: group.group_id,
        room_id: room.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        allocation_order_id: order.id
      })
    )
  end

  defp insert_transferred_allocation!(:credit, group, room, allocation, amount) do
    order = next_allocation_order()

    Repo.insert!(
      CreditAllocation.changeset(%CreditAllocation{}, %{
        group_id: group.group_id,
        room_id: room.room_id,
        credit_lot_id: allocation.credit_lot_id,
        source_operation_id: allocation.source_operation_id,
        amount_cents: amount,
        allocation_order_id: order.id
      })
    )
  end

  defp next_allocation_order do
    Repo.insert!(%FundingAllocationOrder{})
  end

  defp outstanding_for_rooms(rooms) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + max(room.deposit_due_cents - room.deposit_paid_cents, 0)
    end)
  end

  defp apply_open_group(operation) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(operation_id) or not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      if Repo.get(Group, group_id) do
        reject!(
          {:rejected, rejected(operation_id, "group_already_exists", %{group_id: group_id})}
        )
      end

      required = [
        "occurred_on",
        "guest_id",
        "property_id",
        "arrival_on",
        "departure_on",
        "rate_plan",
        "rooms"
      ]

      if Enum.any?(required, &(not Map.has_key?(operation, &1))) do
        reject!({:rejected, rejected(operation_id, "invalid_operation")})
      end

      unless valid_identifier?(operation["guest_id"]) and
               valid_identifier?(operation["property_id"]) do
        reject!({:rejected, rejected(operation_id, "invalid_operation")})
      end

      with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
           {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           true <- Date.compare(departure_on, arrival_on) == :gt,
           {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total, deposit_due} <-
             calculate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
        attrs = %{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, booked_on),
          status: "active",
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1
        }

        group =
          case Repo.insert(Group.changeset(%Group{}, attrs)) do
            {:ok, group} ->
              group

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :group_id) do
                reject!(
                  {:rejected,
                   rejected(operation_id, "group_already_exists", %{group_id: group_id})}
                )
              else
                reject!({:rejected, rejected(operation_id, "invalid_operation")})
              end
          end

        rooms
        |> Enum.with_index()
        |> Enum.each(fn {room, position} ->
          Repo.insert!(
            Room.changeset(%Room{}, %{
              group_id: group_id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: position,
              lodging_total_cents: room.lodging,
              deposit_due_cents: room.deposit_due,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0,
              status: "active"
            })
          )
        end)

        %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        }
      else
        false ->
          reject!({:rejected, rejected(operation_id, "invalid_stay")})

        {:error, :invalid_rate_plan} ->
          reject!({:rejected, rejected(operation_id, "invalid_rate_plan")})

        {:error, :invalid_rooms} ->
          reject!({:rejected, rejected(operation_id, "invalid_rooms")})

        _ ->
          reject!({:rejected, rejected(operation_id, "invalid_stay")})
      end
    end
  end

  defp apply_existing_group_operation(operation, kind) do
    operation_id = Map.get(operation, "operation_id")
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get(Group, group_id) do
        nil ->
          reject!({:rejected, rejected(operation_id, "group_not_found", %{group_id: group_id})})

        group ->
          if Map.has_key?(operation, "expected_revision") and
               operation["expected_revision"] !== group.revision do
            reject!(
              {:rejected,
               rejected(operation_id, "stale_revision", %{
                 group_id: group_id,
                 expected_revision: operation["expected_revision"],
                 actual_revision: group.revision
               })}
            )
          end

          apply_to_existing_group(group, operation, kind)
      end
    end
  end

  defp apply_to_existing_group(group, operation, kind) do
    operation_id = Map.get(operation, "operation_id")

    required = ["operation_id", "occurred_on"]

    if Enum.any?(required, &(not Map.has_key?(operation, &1))) or
         not valid_identifier?(operation_id) do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        apply_validated_group_operation(group, operation, kind, occurred_on)

      :error ->
        reject!(
          {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
        )
    end
  end

  defp apply_validated_group_operation(group, operation, :payment, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      reject!(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        group_id: group.group_id,
        kind: "payment",
        amount_cents: amount,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )

    Repo.insert!(
      CashPayment.changeset(%CashPayment{}, %{
        payment_operation_id: operation_id,
        group_id: group.group_id,
        recorded_cents: amount,
        held_cents: amount
      })
    )

    allocate_funding_to_rooms(group, amount, :cash, operation_id)
    update_group_totals(group, revision)
    record_cash_report_movement(occurred_on, group.property_id, :received_cents, amount)

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :credit, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      reject!(
        {:rejected,
         rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})}
      )
    end

    lots = available_credit_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount do
      reject!(
        {:rejected, rejected(operation_id, "insufficient_credit", %{group_id: group.group_id})}
      )
    end

    revision = group.revision + 1

    allocate_credit_to_rooms(group, lots, amount, operation_id)
    update_group_totals(group, revision)

    Repo.all(
      from allocation in CreditAllocation, where: allocation.source_operation_id == ^operation_id
    )
    |> Enum.each(fn allocation ->
      record_credit_report_event(
        occurred_on,
        allocation.credit_lot_id,
        "apply",
        allocation.amount_cents
      )
    end)

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding - amount,
      revision: revision
    }
  end

  defp apply_validated_group_operation(group, operation, :reschedule, occurred_on) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    if not Map.has_key?(operation, "new_arrival_on") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)

      new_departure =
        try do
          Date.add(group.departure_on, shift)
        rescue
          ArgumentError ->
            reject!(
              {:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})}
            )
        end

      revision = group.revision + 1

      {:ok, _group} =
        Repo.update(
          Ecto.Changeset.change(group,
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: revision
          )
        )

      %{
        group_id: group.group_id,
        new_arrival_on: new_arrival,
        new_departure_on: new_departure,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group.policy_version, new_arrival),
        revision: revision
      }
    else
      _ ->
        reject!({:rejected, rejected(operation_id, "invalid_stay", %{group_id: group.group_id})})
    end
  end

  defp apply_validated_group_operation(group, operation, :cancel, occurred_on) do
    selected_room_ids = active_rooms(group.group_id) |> Enum.map(& &1.room_id)
    settle_selected_rooms(group, operation, occurred_on, selected_room_ids, false)
  end

  defp apply_validated_group_operation(group, operation, :cancel_rooms, occurred_on) do
    supplied = Map.get(operation, "room_ids")

    unless is_list(supplied) and supplied != [] and Enum.all?(supplied, &valid_identifier?/1) do
      reject!(
        {:rejected,
         rejected(operation["operation_id"], "invalid_rooms", %{group_id: group.group_id})}
      )
    end

    active_ids = active_rooms(group.group_id) |> Enum.map(& &1.room_id)

    if length(Enum.uniq(supplied)) != length(supplied) or
         Enum.any?(supplied, &(&1 not in active_ids)) do
      reject!(
        {:rejected,
         rejected(operation["operation_id"], "invalid_rooms", %{group_id: group.group_id})}
      )
    end

    settle_selected_rooms(group, operation, occurred_on, supplied, true)
  end

  defp settle_selected_rooms(group, operation, occurred_on, room_ids, return_room_ids?) do
    operation_id = operation["operation_id"]

    if group.status != "active" do
      reject!(
        {:rejected, rejected(operation_id, "group_not_active", %{group_id: group.group_id})}
      )
    end

    refund_method = Map.get(operation, "refund_method", "cash")

    if refund_method not in ["cash", "hotel_credit"] do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    refundable? =
      case refundable_until(group.policy_version, group.arrival_on) do
        nil -> false
        date -> Date.compare(occurred_on, date) != :gt
      end

    if not refundable? and refund_method == "hotel_credit" do
      reject!(
        {:rejected,
         rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})}
      )
    end

    selected_rooms = Enum.filter(active_rooms(group.group_id), &(&1.room_id in room_ids))
    selected_ids = Enum.map(selected_rooms, & &1.room_id)

    cash_allocations =
      Repo.all(
        from allocation in RoomCashAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^selected_ids,
          order_by: [asc: allocation.id]
      )

    cash_paid = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    cash_sources =
      Enum.reduce(cash_allocations, %{}, fn allocation, acc ->
        Map.update(
          acc,
          allocation.payment_operation_id,
          allocation.amount_cents,
          &(&1 + allocation.amount_cents)
        )
      end)

    refunded = if refundable? and refund_method == "cash", do: cash_paid, else: 0
    retained = if refundable?, do: 0, else: cash_paid
    converted = if refundable? and refund_method == "hotel_credit", do: cash_paid, else: 0
    credit_issued = if converted > 0, do: credit_with_bonus(converted), else: 0

    record_cash_report_movement(occurred_on, group.property_id, :refunded_cents, refunded)
    record_cash_report_movement(occurred_on, group.property_id, :retained_cents, retained)

    record_cash_report_movement(
      occurred_on,
      group.property_id,
      :converted_to_credit_cents,
      converted
    )

    Enum.each(cash_sources, fn
      {nil, _amount} ->
        :ok

      {payment_id, amount} ->
        record_cash_payment_settlement(payment_id, group.group_id, %{
          refunded_cents: if(refunded > 0, do: amount, else: 0),
          retained_cents: if(retained > 0, do: amount, else: 0),
          converted_to_credit_cents: if(converted > 0, do: amount, else: 0)
        })
    end)

    if credit_issued > @max_integer do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^selected_ids,
          order_by: [asc: allocation.id]
      )

    Enum.each(cash_allocations, &Repo.delete!/1)

    Enum.each(cash_sources, fn
      {nil, _amount} ->
        :ok

      {payment_id, amount} ->
        update_cash_payment!(payment_id, %{
          held_cents: {:decrement, amount},
          refunded_cents: {:increment, refunded_amount(refunded, cash_sources, payment_id)},
          retained_cents: {:increment, retained_amount(retained, cash_sources, payment_id)},
          converted_to_credit_cents:
            {:increment, converted_amount(converted, cash_sources, payment_id)}
        })
    end)

    Enum.each(allocations, fn allocation ->
      if refundable? do
        restored =
          restore_credit_allocation(
            allocation.credit_lot_id,
            allocation.amount_cents,
            occurred_on
          )

        record_credit_report_event(
          occurred_on,
          allocation.credit_lot_id,
          "restore",
          restored.restored_cents
        )

        record_credit_report_event(
          occurred_on,
          allocation.credit_lot_id,
          "expired",
          restored.expired_cents
        )

        record_credit_report_event(
          occurred_on,
          allocation.credit_lot_id,
          "absorbed",
          restored.absorbed_cents
        )
      else
        record_credit_report_event(
          occurred_on,
          allocation.credit_lot_id,
          "consume",
          allocation.amount_cents
        )
      end

      Repo.delete!(allocation)
    end)

    Repo.update_all(
      from(room in Room,
        where: room.group_id == ^group.group_id and room.room_id in ^selected_ids
      ),
      set: [status: "cancelled", deposit_paid_cents: 0, cash_paid_cents: 0, credit_paid_cents: 0]
    )

    if credit_issued > 0 do
      lot =
        Repo.insert!(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            issued_on: occurred_on,
            expires_on: Date.add(occurred_on, 365),
            remaining_cents: credit_issued,
            unrecovered_clawback_cents: 0
          })
        )

      record_credit_report_event(occurred_on, lot.id, "issued", credit_issued)

      insert_credit_entitlements(lot, cash_sources)
    end

    if refunded > 0, do: insert_entry(group, "refund", refunded, occurred_on, operation_id)
    if retained > 0, do: insert_entry(group, "retention", retained, occurred_on, operation_id)

    if converted > 0,
      do: insert_entry(group, "cash_to_credit", converted, occurred_on, operation_id)

    revision = group.revision + 1
    _updated_group = update_group_totals(group, revision)

    base = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: revision
    }

    if return_room_ids?, do: Map.put(base, :cancelled_room_ids, selected_ids), else: base
  end

  defp refunded_amount(0, _sources, _payment_id), do: 0

  defp refunded_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp retained_amount(0, _sources, _payment_id), do: 0

  defp retained_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp converted_amount(0, _sources, _payment_id), do: 0

  defp converted_amount(total, sources, payment_id),
    do: min(Map.get(sources, payment_id, 0), total)

  defp restore_credit_allocation(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(amount, lot.unrecovered_clawback_cents || 0)
    remaining_clawback = (lot.unrecovered_clawback_cents || 0) - absorbed
    available = amount - absorbed
    expired = if Date.compare(lot.expires_on, occurred_on) == :lt, do: available, else: 0
    restored = available - expired

    Repo.update!(
      Ecto.Changeset.change(lot,
        unrecovered_clawback_cents: remaining_clawback,
        remaining_cents: lot.remaining_cents + restored
      )
    )

    %{restored_cents: restored, expired_cents: expired, absorbed_cents: absorbed}
  end

  defp record_cash_payment_settlement(payment_id, group_id, changes) do
    case Repo.get_by(CashPaymentSettlement, payment_operation_id: payment_id, group_id: group_id) do
      nil ->
        attrs = Map.merge(%{payment_operation_id: payment_id, group_id: group_id}, changes)
        Repo.insert!(CashPaymentSettlement.changeset(%CashPaymentSettlement{}, attrs))

      settlement ->
        resolved =
          Enum.into(changes, %{}, fn {field, amount} ->
            {field, Map.fetch!(settlement, field) + amount}
          end)

        Repo.update!(Ecto.Changeset.change(settlement, resolved))
    end
  end

  defp insert_credit_entitlements(lot, cash_sources) do
    ordered_sources = ordered_cash_sources(cash_sources)

    {_running, _previous_bonus} =
      Enum.reduce(ordered_sources, {0, 0}, fn {payment_id, amount}, {running, previous_bonus} ->
        next_running = running + amount
        next_bonus = credit_with_bonus(next_running)
        entitlement = next_bonus - previous_bonus

        if amount > 0 do
          Repo.insert!(
            CreditLotEntitlement.changeset(%CreditLotEntitlement{}, %{
              credit_lot_id: lot.id,
              payment_operation_id: payment_id,
              amount_cents: entitlement
            })
          )
        end

        {next_running, next_bonus}
      end)
  end

  defp ordered_cash_sources(sources) do
    durable_ids = sources |> Map.keys() |> Enum.reject(&is_nil/1)

    orders =
      if durable_ids == [] do
        %{}
      else
        Repo.all(
          from record in OperationRecord,
            where: record.operation_id in ^durable_ids,
            select: {record.operation_id, record.id}
        )
        |> Map.new()
      end

    sources
    |> Enum.sort_by(fn
      {nil, _} -> {0, 0}
      {id, _} -> {1, Map.get(orders, id, @max_integer)}
    end)
  end

  defp insert_entry(group, kind, amount, occurred_on, operation_id) do
    Repo.insert!(
      Entry.changeset(%Entry{}, %{
        group_id: group.group_id,
        kind: kind,
        amount_cents: amount,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )
  end

  defp apply_cash_adjustment(operation, action) do
    operation_id = Map.get(operation, "operation_id")
    payment_operation_id = Map.get(operation, "payment_operation_id")

    if not valid_identifier?(operation_id) or not valid_identifier?(payment_operation_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          reject!({:rejected, rejected(operation_id, "operation_not_found")})

        target_record ->
          payment = Repo.get(CashPayment, payment_operation_id)

          group_id =
            if target_record.operation_type == "record_cash_payment" do
              (payment && payment.group_id) || target_record.submission["group_id"] ||
                target_record.result["group_id"]
            end

          group = if valid_identifier?(group_id), do: Repo.get(Group, group_id), else: nil

          if group && Map.has_key?(operation, "expected_revision") &&
               operation["expected_revision"] !== group.revision do
            reject!(
              {:rejected,
               rejected(operation_id, "stale_revision", %{
                 group_id: group.group_id,
                 expected_revision: operation["expected_revision"],
                 actual_revision: group.revision
               })}
            )
          end

          if action == :reduce do
            reduce_payment_cash(operation, target_record, payment, group)
          else
            charge_back_payment(operation, target_record, payment, group)
          end
      end
    end
  end

  defp reduce_payment_cash(operation, target_record, payment, group) do
    operation_id = operation["operation_id"]

    if not applied_cash_payment?(target_record, payment) or is_nil(group) or
         payment.held_cents <= 0 do
      reject!({:rejected, rejected(operation_id, "payment_not_reducible")})
    end

    unless Map.has_key?(operation, "amount_cents") do
      reject!(
        {:rejected, rejected(operation_id, "invalid_operation", %{group_id: group.group_id})}
      )
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      reject!({:rejected, rejected(operation_id, "invalid_amount", %{group_id: group.group_id})})
    end

    if amount > payment.held_cents do
      reject!(
        {:rejected,
         rejected(operation_id, "reduction_exceeds_held_cash", %{group_id: group.group_id})}
      )
    end

    {changed_group_ids, removed_by_group} = remove_held_cash(payment.payment_operation_id, amount)

    Enum.each(removed_by_group, fn {group_id, removed} ->
      changed_group = Repo.get!(Group, group_id)

      record_cash_report_movement(
        accounting_date(operation),
        changed_group.property_id,
        :reduced_cents,
        removed
      )
    end)

    update_cash_payment!(payment.payment_operation_id, %{
      held_cents: payment.held_cents - amount,
      reduced_cents: payment.reduced_cents + amount
    })

    insert_entry(group, "cash_reduced", amount, accounting_date(operation), operation_id)

    updated_groups = update_groups_after_cash_change(group, changed_group_ids)
    updated_group = Map.fetch!(updated_groups, group.group_id)
    revision = updated_group.revision

    %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents:
        updated_group.deposit_due_cents - updated_group.deposit_paid_cents,
      revision: revision
    }
  end

  defp charge_back_payment(operation, target_record, payment, group) do
    operation_id = operation["operation_id"]

    if not applied_cash_payment?(target_record, payment) or is_nil(group) or
         payment.charged_back_cents > 0 or payment.recorded_cents <= payment.reduced_cents do
      reject!({:rejected, rejected(operation_id, "payment_not_chargeable")})
    end

    charged_back = payment.recorded_cents - payment.reduced_cents
    date = accounting_date(operation)

    {changed_group_ids, removed_by_group} =
      remove_held_cash(payment.payment_operation_id, payment.held_cents)

    settlements =
      Repo.all(
        from settlement in CashPaymentSettlement,
          where: settlement.payment_operation_id == ^payment.payment_operation_id
      )

    Enum.each(settlements, fn settlement ->
      settled_group = Repo.get!(Group, settlement.group_id)

      record_cash_report_movement(
        date,
        settled_group.property_id,
        :refunded_cents,
        -settlement.refunded_cents
      )

      record_cash_report_movement(
        date,
        settled_group.property_id,
        :retained_cents,
        -settlement.retained_cents
      )

      record_cash_report_movement(
        date,
        settled_group.property_id,
        :converted_to_credit_cents,
        -settlement.converted_to_credit_cents
      )
    end)

    chargeback_by_group =
      Enum.reduce(settlements, removed_by_group, fn settlement, acc ->
        amount =
          settlement.refunded_cents + settlement.retained_cents +
            settlement.converted_to_credit_cents

        Map.update(acc, settlement.group_id, amount, &(&1 + amount))
      end)

    Enum.each(chargeback_by_group, fn {group_id, amount} ->
      changed_group = Repo.get!(Group, group_id)
      record_cash_report_movement(date, changed_group.property_id, :charged_back_cents, amount)
    end)

    revoke_payment_credit(payment.payment_operation_id, date)

    update_cash_payment!(payment.payment_operation_id, %{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: payment.charged_back_cents + charged_back
    })

    if payment.refunded_cents > 0,
      do: insert_entry(group, "refund_reversal", payment.refunded_cents, date, operation_id)

    if payment.retained_cents > 0,
      do: insert_entry(group, "retention_reversal", payment.retained_cents, date, operation_id)

    if payment.converted_to_credit_cents > 0,
      do:
        insert_entry(
          group,
          "cash_to_credit_reversal",
          payment.converted_to_credit_cents,
          date,
          operation_id
        )

    insert_entry(group, "cash_charged_back", charged_back, date, operation_id)

    updated_groups = update_groups_after_cash_change(group, changed_group_ids)
    updated_group = Map.fetch!(updated_groups, group.group_id)
    revision = updated_group.revision

    %{
      payment_operation_id: payment.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back,
      outstanding_deposit_cents:
        updated_group.deposit_due_cents - updated_group.deposit_paid_cents,
      revision: revision
    }
  end

  defp applied_cash_payment?(record, %CashPayment{} = payment) do
    record.operation_type == "record_cash_payment" and record.result["status"] == "applied" and
      payment.recorded_cents > 0
  end

  defp applied_cash_payment?(_record, _payment), do: false

  defp revoke_payment_credit(payment_operation_id, occurred_on) do
    Repo.all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        order_by: [asc: entitlement.id]
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered = entitlement.amount_cents - removed

      record_credit_report_event(occurred_on, lot.id, "revoke", removed)

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered
        )
      )
    end)
  end

  defp remove_held_cash(_payment_operation_id, 0), do: {MapSet.new(), %{}}

  defp remove_held_cash(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in RoomCashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: allocation.payment_operation_id == ^payment_operation_id,
          where: room.status == "active",
          order_by: [desc: allocation.allocation_order_id, desc: allocation.id]
      )

    {_remaining, touched_group_ids, removed_by_group} =
      Enum.reduce_while(allocations, {amount, MapSet.new(), %{}}, fn allocation,
                                                                     {remaining,
                                                                      touched_group_ids,
                                                                      removed_by_group} ->
        removed = min(remaining, allocation.amount_cents)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - removed)
          )
        end

        room = Repo.get_by!(Room, group_id: allocation.group_id, room_id: allocation.room_id)

        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents - removed,
            cash_paid_cents: room.cash_paid_cents - removed
          )
        )

        next_remaining = remaining - removed
        touched_group_ids = MapSet.put(touched_group_ids, allocation.group_id)

        removed_by_group =
          Map.update(removed_by_group, allocation.group_id, removed, &(&1 + removed))

        if next_remaining == 0,
          do: {:halt, {0, touched_group_ids, removed_by_group}},
          else: {:cont, {next_remaining, touched_group_ids, removed_by_group}}
      end)

    {touched_group_ids, removed_by_group}
  end

  defp update_groups_after_cash_change(addressed_group, changed_group_ids) do
    changed_group_ids = MapSet.put(changed_group_ids, addressed_group.group_id)

    Enum.reduce(changed_group_ids, %{}, fn group_id, updated ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      Map.put(updated, group_id, update_group_totals(group, group.revision + 1))
    end)
  end

  defp update_cash_payment!(payment_id, changes) do
    payment = Repo.get!(CashPayment, payment_id)

    resolved =
      Enum.reduce(changes, %{}, fn
        {field, {:increment, amount}}, acc ->
          Map.put(acc, field, Map.fetch!(payment, field) + amount)

        {field, {:decrement, amount}}, acc ->
          Map.put(acc, field, Map.fetch!(payment, field) - amount)

        {field, value}, acc ->
          Map.put(acc, field, value)
      end)

    Repo.update!(Ecto.Changeset.change(payment, resolved))
  end

  defp accounting_date(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, date} -> date
      :error -> Date.utc_today()
    end
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.position, asc: room.id]
    )
  end

  defp allocate_funding_to_rooms(group, amount, :cash, payment_operation_id) do
    active_rooms(group.group_id)
    |> Enum.reduce_while(amount, fn room, remaining ->
      available = max(room.deposit_due_cents - room.deposit_paid_cents, 0)
      allocated = min(available, remaining)

      if allocated > 0 do
        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents + allocated,
            cash_paid_cents: room.cash_paid_cents + allocated
          )
        )

        Repo.insert!(
          RoomCashAllocation.changeset(%RoomCashAllocation{}, %{
            group_id: group.group_id,
            room_id: room.room_id,
            payment_operation_id: payment_operation_id,
            amount_cents: allocated,
            allocation_order_id: next_allocation_order().id
          })
        )
      end

      next = remaining - allocated
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp allocate_credit_to_rooms(group, lots, amount, operation_id) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      if consumed > 0 do
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - consumed))
        allocate_credit_funding_to_rooms(group, consumed, operation_id, lot.id)
      end

      next = remaining - consumed
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp allocate_credit_funding_to_rooms(group, amount, operation_id, lot_id) do
    active_rooms(group.group_id)
    |> Enum.reduce_while(amount, fn room, remaining ->
      available = max(room.deposit_due_cents - room.deposit_paid_cents, 0)
      allocated = min(available, remaining)

      if allocated > 0 do
        Repo.update!(
          Ecto.Changeset.change(room,
            deposit_paid_cents: room.deposit_paid_cents + allocated,
            credit_paid_cents: room.credit_paid_cents + allocated
          )
        )

        Repo.insert!(
          CreditAllocation.changeset(%CreditAllocation{}, %{
            group_id: group.group_id,
            room_id: room.room_id,
            credit_lot_id: lot_id,
            source_operation_id: operation_id,
            amount_cents: allocated,
            allocation_order_id: next_allocation_order().id
          })
        )
      end

      next = remaining - allocated
      if next == 0, do: {:halt, 0}, else: {:cont, next}
    end)
  end

  defp update_group_totals(group, revision) do
    rooms = active_rooms(group.group_id)

    attrs = %{
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2)),
      deposit_due_cents: Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2)),
      deposit_paid_cents: Enum.reduce(rooms, 0, &(&1.deposit_paid_cents + &2)),
      cash_paid_cents: Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2)),
      credit_paid_cents: Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2)),
      revision: revision
    }

    Repo.update!(Ecto.Changeset.change(group, attrs))
  end

  defp credit_shortfall_total do
    lots = Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)

    Enum.reduce(lots, 0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in CreditAllocation,
            join: group in Group,
            on: allocation.group_id == group.group_id,
            where: allocation.credit_lot_id == ^lot.id and group.status == "active",
            select: sum(allocation.amount_cents)
        ) || 0

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on and
            lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp available_credit_total(on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on >= ^on,
        select: sum(lot.remaining_cents)
    ) || 0
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy_version, _arrival_on), do: nil

  defp credit_with_bonus(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp calculate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          lodging = nights * rate
          deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          if lodging <= @max_integer do
            {:ok,
             %{room_id: room_id, nightly_rate_cents: rate, lodging: lodging, deposit_due: deposit}}
          else
            :error
          end

        _ ->
          :error
      end)

    if rooms == [] or Enum.any?(parsed, &(&1 == :error)) do
      {:error, :invalid_rooms}
    else
      values = Enum.map(parsed, fn {:ok, room} -> room end)
      room_ids = Enum.map(values, & &1.room_id)
      lodging_total = Enum.reduce(values, 0, &(&1.lodging + &2))

      if length(Enum.uniq(room_ids)) != length(room_ids) or lodging_total > @max_integer do
        {:error, :invalid_rooms}
      else
        deposit_due =
          case rate_plan do
            "flexible" -> Enum.reduce(values, 0, &(&1.deposit_due + &2))
            "advance_purchase" -> lodging_total
          end

        if deposit_due > @max_integer do
          {:error, :invalid_rooms}
        else
          {:ok, values, lodging_total, deposit_due}
        end
      end
    end
  end

  defp calculate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, :invalid_rooms}

  defp parse_rate_plan("flexible"), do: {:ok, "flexible"}
  defp parse_rate_plan("advance_purchase"), do: {:ok, "advance_purchase"}
  defp parse_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, extra)
  end

  defp reject!({:rejected, result}), do: throw({:handled_rejection, result})

  defp operation_type(operation), do: if(is_binary(operation["type"]), do: operation["type"])

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
