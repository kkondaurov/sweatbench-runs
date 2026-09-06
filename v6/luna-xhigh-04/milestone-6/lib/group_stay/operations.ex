defmodule GroupStay.Operations do
  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset

  alias GroupStay.{
    CashAllocation,
    CashPayment,
    CreditAllocation,
    CreditLot,
    CreditLotContribution,
    FinanceCreditEvent,
    FinanceMovement,
    FinanceOpeningCash,
    FinanceOpeningLot,
    FinanceReporting,
    Group,
    Ledger,
    OperationRecord,
    Repo,
    Room
  }

  @active "active"
  @cancelled "cancelled"
  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted "converted"
  @charged_back "charged_back"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_cutover ~D[2027-01-01]

  @type operation :: map()

  @spec process_batch([operation()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        ensure_room_accounting!(group)

        group
        |> Repo.preload(:rooms)
        |> serialize_group()
    end
  end

  @spec guest_credit(String.t(), Date.t()) :: map()
  def guest_credit(guest_id, on) do
    lots = available_credit_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" => Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  @spec daily_finance_report(Date.t()) :: {:ok, map()} | {:error, String.t()}
  def daily_finance_report(date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        {:error, "report_not_available"}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, "report_not_available"}
        else
          {:ok, build_daily_finance_report(reporting, date)}
        end
    end
  end

  @spec ledger_totals(Date.t()) :: map()
  def ledger_totals(on \\ Date.utc_today()) do
    ledger = Repo.get!(Ledger, 1)

    %{
      "cash_held_cents" => ledger.cash_held_cents,
      "cash_refunded_cents" => ledger.cash_refunded_cents,
      "cash_retained_cents" => ledger.cash_retained_cents,
      "cash_converted_to_credit_cents" => ledger.cash_converted_to_credit_cents,
      "cash_reduced_cents" => ledger.cash_reduced_cents,
      "cash_charged_back_cents" => ledger.cash_charged_back_cents,
      "credit_liability_cents" => credit_liability_as_of(on),
      "credit_shortfall_cents" => credit_shortfall_cents()
    }
  end

  @spec get_operation_result(String.t()) :: map() | nil
  def get_operation_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  @spec get_payment_reconciliation(String.t()) ::
          {:ok, map()} | {:error, :operation_not_found | :payment_not_reconcilable}
  def get_payment_reconciliation(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record when record.type != "record_cash_payment" ->
        {:error, :payment_not_reconcilable}

      record ->
        case value(record.result, "status") do
          "applied" ->
            with {:ok, group_id} <- required_result_identifier(record.result, "group_id"),
                 {:ok, payment} <- reconciliation_payment(record, group_id) do
              statement = %{
                "payment_operation_id" => payment_operation_id,
                "original_group_id" => group_id,
                "recorded_cents" => payment.recorded_cents,
                "held_cents" => payment.held_cents,
                "refunded_cents" => payment.refunded_cents,
                "retained_cents" => payment.retained_cents,
                "converted_to_credit_cents" => payment.converted_to_credit_cents,
                "reduced_cents" => payment.reduced_cents,
                "charged_back_cents" => payment.charged_back_cents
              }

              statement =
                if payment.transfer_participated do
                  Map.put(statement, "held_by_group", held_cash_by_group(payment_operation_id))
                else
                  statement
                end

              {:ok, statement}
            else
              _ -> {:error, :payment_not_reconcilable}
            end

          _ ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  @spec parse_report_date(String.t() | nil) :: {:ok, Date.t()} | {:error, String.t()}
  def parse_report_date(nil), do: {:ok, Date.utc_today()}

  def parse_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def parse_report_date(_value), do: {:error, "invalid_date"}

  @spec parse_finance_report_date(String.t()) ::
          {:ok, Date.t()} | {:error, String.t()}
  def parse_finance_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_reporting_date"}
    end
  end

  def parse_finance_report_date(_value), do: {:error, "invalid_reporting_date"}

  defp build_daily_finance_report(reporting, date) do
    movements =
      Repo.all(
        from(m in FinanceMovement,
          where: m.posting_on >= ^reporting.starts_on and m.posting_on <= ^date
        )
      )

    {before_movements, today_movements} =
      Enum.split_with(movements, &(Date.compare(&1.posting_on, date) == :lt))

    opening_cash =
      Repo.all(from(c in FinanceOpeningCash, select: {c.property_id, c.held_cents}))
      |> Map.new()

    cash_before = aggregate_cash_movements(before_movements)
    cash_today = aggregate_cash_movements(today_movements)

    properties =
      (Map.keys(opening_cash) ++ Map.keys(cash_before) ++ Map.keys(cash_today))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        opening =
          Map.get(opening_cash, property_id, 0) + cash_net(Map.get(cash_before, property_id))

        today = Map.get(cash_today, property_id, zero_cash_movement())
        closing = opening + cash_net(today)

        {property_id, opening, today, closing}
      end)
      |> Enum.reject(fn {_property_id, opening, today, closing} ->
        opening == 0 and closing == 0 and cash_net_zero?(today)
      end)
      |> Enum.map(fn {property_id, opening, today, closing} ->
        %{
          "property_id" => property_id,
          "opening_held_cents" => opening,
          "movements" => serialize_cash_movement(today),
          "closing_held_cents" => closing
        }
      end)

    {expired_before, expired_today} = expiry_movements(reporting, date)
    credit_before = aggregate_credit_movements(before_movements)
    credit_today = aggregate_credit_movements(today_movements)
    credit_before = Map.update!(credit_before, :expired_cents, &(&1 + expired_before))
    credit_today = Map.update!(credit_today, :expired_cents, &(&1 + expired_today))

    credit_opening =
      reporting.opening_credit_liability_cents + credit_liability_net(credit_before)

    credit_closing = credit_opening + credit_liability_net(credit_today)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash,
      "credit" => %{
        "opening_liability_cents" => credit_opening,
        "movements" => serialize_credit_movement(credit_today),
        "closing_liability_cents" => credit_closing
      }
    }
  end

  defp aggregate_cash_movements(movements) do
    Enum.reduce(movements, %{}, fn movement, properties ->
      if movement.property_id do
        Map.update(
          properties,
          movement.property_id,
          cash_movement_values(movement),
          &sum_cash_movements(&1, cash_movement_values(movement))
        )
      else
        properties
      end
    end)
  end

  defp aggregate_credit_movements(movements) do
    Enum.reduce(movements, zero_credit_movement(), fn movement, totals ->
      Enum.reduce(credit_movement_fields(), totals, fn field, totals ->
        Map.update!(totals, field, &(&1 + Map.fetch!(movement, field)))
      end)
    end)
  end

  defp cash_movement_values(movement) do
    Map.new(cash_movement_fields(), &{&1, Map.fetch!(movement, &1)})
  end

  defp sum_cash_movements(left, right) do
    Enum.reduce(cash_movement_fields(), left, fn field, values ->
      Map.update!(values, field, &(&1 + Map.fetch!(right, field)))
    end)
  end

  defp cash_net(nil), do: 0

  defp cash_net(movement) do
    movement.received_cents + movement.transferred_in_cents - movement.transferred_out_cents -
      movement.refunded_cents - movement.retained_cents - movement.converted_to_credit_cents -
      movement.reduced_cents - movement.charged_back_cents
  end

  defp cash_net_zero?(movement),
    do:
      cash_net(movement) == 0 and
        Enum.all?(cash_movement_fields(), &(Map.fetch!(movement, &1) == 0))

  defp credit_liability_net(movement) do
    movement.issued_cents - movement.expired_cents - movement.consumed_cents -
      movement.revoked_cents - movement.absorbed_cents
  end

  defp zero_cash_movement do
    Map.new(cash_movement_fields(), &{&1, 0})
  end

  defp zero_credit_movement do
    Map.new(credit_movement_fields(), &{&1, 0})
  end

  defp cash_movement_fields do
    [
      :received_cents,
      :transferred_in_cents,
      :transferred_out_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents
    ]
  end

  defp credit_movement_fields do
    [:issued_cents, :expired_cents, :consumed_cents, :revoked_cents, :absorbed_cents]
  end

  defp serialize_cash_movement(movement) do
    Map.new(cash_movement_fields(), fn field ->
      {Atom.to_string(field), Map.fetch!(movement, field)}
    end)
  end

  defp serialize_credit_movement(movement) do
    Map.new(credit_movement_fields(), fn field ->
      {Atom.to_string(field), Map.fetch!(movement, field)}
    end)
  end

  defp expiry_movements(reporting, date) do
    opening_lots =
      Repo.all(from(l in FinanceOpeningLot, select: {l.credit_lot_id, l}))
      |> Map.new()

    event_limit = date

    events_by_lot =
      Repo.all(
        from(e in FinanceCreditEvent,
          where: e.posting_on >= ^reporting.starts_on and e.posting_on <= ^event_limit
        )
      )
      |> Enum.group_by(& &1.credit_lot_id)

    Repo.all(from(l in CreditLot, where: l.expires_on <= ^date))
    |> Enum.reduce({0, 0}, fn lot, {before, today} ->
      expiry_on = lot.expires_on
      opening_lot = Map.get(opening_lots, lot.id)

      eligible? =
        is_nil(opening_lot) or Date.compare(lot.expires_on, reporting.starts_on) == :gt

      if eligible? and Date.compare(expiry_on, reporting.starts_on) != :lt and
           Date.compare(expiry_on, date) != :gt do
        initial_available =
          case opening_lot do
            nil ->
              0

            opening ->
              if Date.compare(opening.expires_on, reporting.starts_on) == :gt do
                opening.remaining_cents
              else
                0
              end
          end

        available_at_expiry =
          initial_available +
            (events_by_lot
             |> Map.get(lot.id, [])
             |> Enum.filter(&(Date.compare(&1.posting_on, lot.expires_on) == :lt))
             |> Enum.sum_by(& &1.available_delta_cents))

        amount = max(available_at_expiry, 0)

        cond do
          amount == 0 -> {before, today}
          Date.compare(expiry_on, date) == :eq -> {before, today + amount}
          true -> {before + amount, today}
        end
      else
        {before, today}
      end
    end)
  end

  defp finance_snapshot_if_reporting do
    if Repo.get(FinanceReporting, 1) do
      ensure_all_room_accounting!()
      finance_snapshot()
    end
  end

  defp finance_snapshot do
    groups =
      Repo.all(Group)
      |> Map.new(fn group ->
        {group.group_id,
         %{
           property_id: group.property_id,
           status: group.status,
           guest_id: group.guest_id,
           rate_plan: group.rate_plan,
           policy_version: group.policy_version,
           booked_on: group.booked_on,
           arrival_on: group.arrival_on
         }}
      end)

    cash_allocations =
      Repo.all(CashAllocation)
      |> Map.new(fn allocation ->
        {allocation.id,
         %{
           id: allocation.id,
           group_id: allocation.group_id,
           room_id: allocation.room_id,
           payment_operation_id: allocation.payment_operation_id,
           amount_cents: allocation.amount_cents,
           disposition: allocation.disposition
         }}
      end)

    credit_allocations =
      Repo.all(CreditAllocation)
      |> Map.new(fn allocation ->
        {allocation.id,
         %{
           id: allocation.id,
           group_id: allocation.group_id,
           credit_lot_id: allocation.credit_lot_id,
           amount_cents: allocation.amount_cents
         }}
      end)

    credit_lots =
      Repo.all(CreditLot)
      |> Map.new(fn lot ->
        {lot.id,
         %{
           id: lot.id,
           remaining_cents: lot.remaining_cents,
           unrecovered_clawback_cents: lot.unrecovered_clawback_cents || 0,
           expires_on: lot.expires_on
         }}
      end)

    %{
      groups: groups,
      cash_allocations: cash_allocations,
      credit_allocations: credit_allocations,
      credit_lots: credit_lots
    }
  end

  defp opening_cash_by_property(snapshot) do
    Enum.reduce(snapshot.cash_allocations, %{}, fn {_id, allocation}, properties ->
      if allocation.disposition == @held and
           Map.get(snapshot.groups[allocation.group_id], :status) == @active do
        property_id = snapshot.groups[allocation.group_id].property_id

        Map.update(
          properties,
          property_id,
          allocation.amount_cents,
          &(&1 + allocation.amount_cents)
        )
      else
        properties
      end
    end)
  end

  defp applied_result?(result), do: is_map(result) and value(result, "status") == "applied"

  defp record_finance_effect!(operation, _result, before) do
    after_snapshot = finance_snapshot()
    operation_id = value(operation, "operation_id")
    {:ok, occurred_on} = parse_date(operation, "occurred_on")
    reporting = Repo.get!(FinanceReporting, 1)
    posting_on = later_date(occurred_on, reporting.starts_on)
    cash_effects = finance_cash_effects(operation, before, after_snapshot)
    {credit_effect, credit_events} = finance_credit_effects(operation, before, after_snapshot)

    cash_effects =
      cash_effects
      |> Enum.reject(fn {_property_id, movement} -> cash_movement_zero?(movement) end)
      |> Enum.sort_by(&elem(&1, 0))

    cash_effects =
      if cash_effects == [] and credit_movement_nonzero?(credit_effect) do
        [{nil, zero_cash_movement()}]
      else
        cash_effects
      end

    cash_effects
    |> attach_credit_effect(credit_effect)
    |> Enum.each(fn {property_id, cash_movement, credit_movement} ->
      Repo.insert!(%FinanceMovement{
        operation_id: operation_id,
        posting_on: posting_on,
        property_id: property_id,
        received_cents: cash_movement.received_cents,
        transferred_in_cents: cash_movement.transferred_in_cents,
        transferred_out_cents: cash_movement.transferred_out_cents,
        refunded_cents: cash_movement.refunded_cents,
        retained_cents: cash_movement.retained_cents,
        converted_to_credit_cents: cash_movement.converted_to_credit_cents,
        reduced_cents: cash_movement.reduced_cents,
        charged_back_cents: cash_movement.charged_back_cents,
        issued_cents: credit_movement.issued_cents,
        expired_cents: credit_movement.expired_cents,
        consumed_cents: credit_movement.consumed_cents,
        revoked_cents: credit_movement.revoked_cents,
        absorbed_cents: credit_movement.absorbed_cents
      })
    end)

    Enum.each(credit_events, fn {credit_lot_id, available_delta_cents} ->
      Repo.insert!(%FinanceCreditEvent{
        operation_id: operation_id,
        credit_lot_id: credit_lot_id,
        posting_on: posting_on,
        available_delta_cents: available_delta_cents
      })
    end)
  end

  defp attach_credit_effect([], _credit_effect), do: []

  defp attach_credit_effect([{property_id, cash_movement} | rest], credit_effect) do
    [
      {property_id, cash_movement, credit_effect}
      | Enum.map(rest, &{elem(&1, 0), elem(&1, 1), zero_credit_movement()})
    ]
  end

  defp cash_movement_zero?(movement),
    do: Enum.all?(cash_movement_fields(), &(Map.fetch!(movement, &1) == 0))

  defp credit_movement_nonzero?(movement),
    do: Enum.any?(credit_movement_fields(), &(Map.fetch!(movement, &1) != 0))

  defp finance_cash_effects(operation, before, after_snapshot) do
    case value(operation, "type") do
      "record_cash_payment" ->
        group_id = value(operation, "group_id")
        amount = value(operation, "amount_cents") || 0
        add_cash_effect(%{}, property_for_group(before, group_id), :received_cents, amount)

      "transfer_deposit" ->
        source_group_id = value(operation, "source_group_id")
        destination_group_id = value(operation, "destination_group_id")
        source_before = held_cash_for_group(before, source_group_id)
        source_after = held_cash_for_group(after_snapshot, source_group_id)
        destination_before = held_cash_for_group(before, destination_group_id)
        destination_after = held_cash_for_group(after_snapshot, destination_group_id)
        source_amount = max(source_before - source_after, 0)
        destination_amount = max(destination_after - destination_before, 0)

        %{}
        |> add_cash_effect(
          property_for_group(before, source_group_id),
          :transferred_out_cents,
          source_amount
        )
        |> add_cash_effect(
          property_for_group(before, destination_group_id),
          :transferred_in_cents,
          destination_amount
        )

      "cancel_group" ->
        settlement_cash_effects(before, after_snapshot, operation, nil)

      "cancel_rooms" ->
        settlement_cash_effects(before, after_snapshot, operation, nil)

      "reduce_cash_payment" ->
        payment_operation_id = value(operation, "payment_operation_id")

        Enum.reduce(before.cash_allocations, %{}, fn {_id, allocation}, effects ->
          after_allocation = Map.get(after_snapshot.cash_allocations, allocation.id)
          remaining = if after_allocation, do: after_allocation.amount_cents, else: 0

          if allocation.payment_operation_id == payment_operation_id and
               allocation.disposition == @held and allocation.amount_cents > remaining do
            add_cash_effect(
              effects,
              property_for_group(before, allocation.group_id),
              :reduced_cents,
              allocation.amount_cents - remaining
            )
          else
            effects
          end
        end)

      "charge_back_payment" ->
        payment_operation_id = value(operation, "payment_operation_id")

        Enum.reduce(before.cash_allocations, %{}, fn {_id, allocation}, effects ->
          after_allocation = Map.get(after_snapshot.cash_allocations, allocation.id)

          if (allocation.payment_operation_id == payment_operation_id and
                after_allocation) && after_allocation.disposition == @charged_back do
            property_id = property_for_group(before, allocation.group_id)

            case allocation.disposition do
              @held ->
                add_cash_effect(
                  effects,
                  property_id,
                  :charged_back_cents,
                  allocation.amount_cents
                )

              @refunded ->
                effects
                |> add_cash_effect(property_id, :refunded_cents, -allocation.amount_cents)
                |> add_cash_effect(property_id, :charged_back_cents, allocation.amount_cents)

              @retained ->
                effects
                |> add_cash_effect(property_id, :retained_cents, -allocation.amount_cents)
                |> add_cash_effect(property_id, :charged_back_cents, allocation.amount_cents)

              @converted ->
                effects
                |> add_cash_effect(
                  property_id,
                  :converted_to_credit_cents,
                  -allocation.amount_cents
                )
                |> add_cash_effect(property_id, :charged_back_cents, allocation.amount_cents)

              _ ->
                effects
            end
          else
            effects
          end
        end)

      _ ->
        %{}
    end
  end

  defp settlement_cash_effects(before, after_snapshot, _operation, _unused) do
    Enum.reduce(before.cash_allocations, %{}, fn {_id, allocation}, effects ->
      after_allocation = Map.get(after_snapshot.cash_allocations, allocation.id)

      if (allocation.disposition == @held and after_allocation) &&
           after_allocation.disposition in [@refunded, @retained, @converted] do
        field =
          case after_allocation.disposition do
            @refunded -> :refunded_cents
            @retained -> :retained_cents
            @converted -> :converted_to_credit_cents
          end

        add_cash_effect(
          effects,
          property_for_group(before, allocation.group_id),
          field,
          after_allocation.amount_cents
        )
      else
        effects
      end
    end)
  end

  defp add_cash_effect(effects, nil, _field, _amount), do: effects

  defp add_cash_effect(effects, property_id, field, amount) do
    movement = Map.get(effects, property_id, zero_cash_movement())
    movement = Map.update!(movement, field, &(&1 + amount))
    Map.put(effects, property_id, movement)
  end

  defp held_cash_for_group(snapshot, group_id) do
    snapshot.cash_allocations
    |> Map.values()
    |> Enum.filter(&(&1.group_id == group_id and &1.disposition == @held))
    |> Enum.sum_by(& &1.amount_cents)
  end

  defp property_for_group(snapshot, group_id) do
    case Map.get(snapshot.groups, group_id) do
      nil -> nil
      group -> group.property_id
    end
  end

  defp finance_credit_effects(operation, before, after_snapshot) do
    lot_ids =
      (Map.keys(before.credit_lots) ++ Map.keys(after_snapshot.credit_lots))
      |> Enum.uniq()

    credit_events =
      lot_ids
      |> Enum.map(fn lot_id ->
        before_amount = get_in(before, [:credit_lots, lot_id, :remaining_cents]) || 0
        after_amount = get_in(after_snapshot, [:credit_lots, lot_id, :remaining_cents]) || 0
        {lot_id, after_amount - before_amount}
      end)
      |> Enum.reject(&(elem(&1, 1) == 0))

    movement = zero_credit_movement()

    movement =
      case value(operation, "type") do
        type when type in ["cancel_group", "cancel_rooms"] ->
          settlement_credit_effects(operation, before, after_snapshot, movement)

        "charge_back_payment" ->
          chargeback_credit_effects(operation, before, after_snapshot, movement)

        _ ->
          movement
      end

    issued =
      Enum.reduce(after_snapshot.credit_lots, 0, fn {lot_id, lot}, total ->
        if not Map.has_key?(before.credit_lots, lot_id),
          do: total + lot.remaining_cents,
          else: total
      end)

    {%{movement | issued_cents: movement.issued_cents + issued}, credit_events}
  end

  defp settlement_credit_effects(operation, before, after_snapshot, movement) do
    group_id = value(operation, "group_id")
    {:ok, occurred_on} = parse_date(operation, "occurred_on")
    refundable? = report_refundable?(before, group_id, occurred_on)
    deleted = deleted_credit_allocations(before, after_snapshot)

    if refundable? do
      Enum.reduce(deleted, movement, fn allocation, movement ->
        before_lot = Map.get(before.credit_lots, allocation.credit_lot_id)
        after_lot = Map.get(after_snapshot.credit_lots, allocation.credit_lot_id)
        before_remaining = if before_lot, do: before_lot.remaining_cents, else: 0
        after_remaining = if after_lot, do: after_lot.remaining_cents, else: 0
        before_unrecovered = if before_lot, do: before_lot.unrecovered_clawback_cents, else: 0
        absorbed = min(before_unrecovered, allocation.amount_cents)
        restored = max(after_remaining - before_remaining, 0)
        expired = max(allocation.amount_cents - absorbed - restored, 0)

        %{
          movement
          | expired_cents: movement.expired_cents + expired,
            absorbed_cents: movement.absorbed_cents + absorbed
        }
      end)
    else
      %{movement | consumed_cents: Enum.sum_by(deleted, & &1.amount_cents)}
    end
  end

  defp chargeback_credit_effects(operation, before, after_snapshot, movement) do
    {:ok, occurred_on} = parse_date(operation, "occurred_on")

    revoked =
      Enum.reduce(before.credit_lots, 0, fn {lot_id, lot}, total ->
        after_lot = Map.get(after_snapshot.credit_lots, lot_id)
        after_remaining = if after_lot, do: after_lot.remaining_cents, else: lot.remaining_cents

        if Date.compare(lot.expires_on, occurred_on) == :gt do
          total + max(lot.remaining_cents - after_remaining, 0)
        else
          total
        end
      end)

    %{movement | revoked_cents: revoked}
  end

  defp deleted_credit_allocations(before, after_snapshot) do
    before.credit_allocations
    |> Map.values()
    |> Enum.reject(&Map.has_key?(after_snapshot.credit_allocations, &1.id))
  end

  defp report_refundable?(snapshot, group_id, occurred_on) do
    case Map.get(snapshot.groups, group_id) do
      nil ->
        false

      group ->
        policy = group.policy_version || policy_version_for(group.rate_plan, group.booked_on)

        case policy_window(policy) do
          nil -> false
          window -> Date.diff(group.arrival_on, occurred_on) >= window
        end
    end
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    case validate_operation_id(operation_id) do
      :ok -> process_durably(operation, operation_id)
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_durably(operation, operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case reserve_operation(operation, operation_id) do
          {:new, record} ->
            before_finance = finance_snapshot_if_reporting()
            result = process_new_operation(operation, operation_id)

            if applied_result?(result) and operation_type(operation) != "start_finance_reporting" and
                 before_finance do
              record_finance_effect!(operation, result, before_finance)
            end

            record
            |> Changeset.change(result: result)
            |> Repo.update!()

            result

          {:existing, record} ->
            if equivalent_payload?(record.payload, operation) do
              record.result
            else
              rejected(operation_id, "operation_id_conflict")
            end
        end
      end)

    result
  end

  defp reserve_operation(operation, operation_id) do
    {inserted, _rows} =
      Repo.insert_all(
        OperationRecord,
        [
          %{
            operation_id: operation_id,
            type: operation_type(operation),
            payload: operation
          }
        ],
        on_conflict: :nothing
      )

    case inserted do
      1 -> {:new, Repo.get_by!(OperationRecord, operation_id: operation_id)}
      0 -> {:existing, Repo.get_by!(OperationRecord, operation_id: operation_id)}
    end
  end

  defp process_new_operation(operation, operation_id) do
    with type when is_binary(type) <- value(operation, "type"),
         {:ok, result} <- dispatch(type, operation, operation_id) do
      result
    else
      {:error, code} -> rejected(operation_id, code)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp dispatch("start_finance_reporting", operation, operation_id) do
    {:ok, start_finance_reporting(operation, operation_id)}
  end

  defp dispatch("open_group", operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      result =
        if Repo.get(Group, group_id) do
          rejected(operation_id, "group_already_exists", group_id)
        else
          with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
               {:ok, property_id} <- required_identifier(operation, "property_id") do
            open_group(operation, operation_id, group_id, guest_id, property_id)
          else
            {:error, code} -> rejected(operation_id, code, group_id)
          end
        end

      {:ok, result}
    end
  end

  defp dispatch(type, operation, operation_id)
       when type in [
              "record_cash_payment",
              "reschedule_group",
              "cancel_group",
              "cancel_rooms",
              "apply_hotel_credit"
            ] do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      result =
        case Repo.get(Group, group_id) do
          nil ->
            rejected(operation_id, "group_not_found", group_id)

          group ->
            group = ensure_room_accounting!(group)
            group = Repo.preload(group, :rooms)
            apply_existing_group_operation(type, operation, operation_id, group)
        end

      {:ok, result}
    end
  end

  defp dispatch("transfer_deposit", operation, operation_id) do
    with {:ok, source_group_id} <- required_identifier(operation, "source_group_id"),
         {:ok, destination_group_id} <- required_identifier(operation, "destination_group_id") do
      result =
        case Repo.get(Group, source_group_id) do
          nil ->
            rejected(operation_id, "group_not_found", source_group_id)

          source_group ->
            case Repo.get(Group, destination_group_id) do
              nil ->
                rejected(operation_id, "group_not_found", destination_group_id)

              destination_group ->
                transfer_deposit(
                  operation,
                  operation_id,
                  source_group,
                  destination_group
                )
            end
        end

      {:ok, result}
    end
  end

  defp dispatch(type, operation, operation_id)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      result =
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil ->
            rejected(operation_id, "operation_not_found")

          record ->
            apply_payment_operation(
              type,
              operation,
              operation_id,
              payment_operation_id,
              record
            )
        end

      {:ok, result}
    else
      {:error, code} -> {:ok, rejected(operation_id, code)}
    end
  end

  defp dispatch(_type, _operation, _operation_id), do: {:error, "invalid_operation"}

  defp start_finance_reporting(operation, operation_id) do
    with {:ok, starts_on} <- parse_reporting_date(operation) do
      if Repo.get(FinanceReporting, 1) do
        rejected(operation_id, "reporting_already_started")
      else
        ensure_all_room_accounting!()
        snapshot = finance_snapshot()
        opening_credit_liability_cents = credit_liability_as_of(starts_on)

        Repo.insert!(%FinanceReporting{
          id: 1,
          starts_on: starts_on,
          opening_credit_liability_cents: opening_credit_liability_cents
        })

        snapshot
        |> opening_cash_by_property()
        |> Enum.each(fn {property_id, held_cents} ->
          Repo.insert!(%FinanceOpeningCash{property_id: property_id, held_cents: held_cents})
        end)

        Enum.each(snapshot.credit_lots, fn {_lot_id, lot} ->
          Repo.insert!(%FinanceOpeningLot{
            credit_lot_id: lot.id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          })
        end)

        %{
          "operation_id" => operation_id,
          "status" => "applied",
          "starts_on" => Date.to_iso8601(starts_on)
        }
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp open_group(operation, operation_id, group_id, guest_id, property_id) do
    with {:ok, booked_on} <- parse_date(operation, "occurred_on"),
         {:ok, arrival_on} <- parse_date(operation, "arrival_on"),
         {:ok, departure_on} <- parse_date(operation, "departure_on"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         {:ok, room_data} <- validate_rooms(operation, departure_on, arrival_on, rate_plan) do
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_cents))

      group = %Group{
        group_id: group_id,
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
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        revision: 1
      }

      Repo.insert!(group)

      room_data
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          status: @active,
          deposit_due_cents: room.deposit_cents,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

      applied(operation_id, %{
        "group_id" => group_id,
        "deposit_due_cents" => deposit_due_cents,
        "revision" => 1
      })
    else
      {:error, code} -> rejected(operation_id, code, group_id)
    end
  end

  defp apply_existing_group_operation(type, operation, operation_id, group) do
    case check_expected_revision(operation, operation_id, group) do
      :ok ->
        case type do
          "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
          "reschedule_group" -> reschedule_group(operation, operation_id, group)
          "cancel_group" -> cancel_group(operation, operation_id, group)
          "cancel_rooms" -> cancel_rooms(operation, operation_id, group)
          "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
        end

      {:error, result} ->
        result
    end
  end

  defp transfer_deposit(operation, operation_id, source_group, destination_group) do
    case check_expected_revision(operation, operation_id, source_group) do
      {:error, result} ->
        result

      :ok ->
        case check_expected_revision(
               operation,
               "destination_expected_revision",
               operation_id,
               destination_group
             ) do
          {:error, result} ->
            result

          :ok ->
            source_active? = source_group.status == @active
            destination_active? = destination_group.status == @active

            cond do
              source_group.group_id == destination_group.group_id or
                  source_group.guest_id != destination_group.guest_id ->
                rejected(operation_id, "invalid_transfer")

              not source_active? ->
                rejected(operation_id, "group_not_active", source_group.group_id)

              not destination_active? ->
                rejected(operation_id, "group_not_active", destination_group.group_id)

              not valid_occurred_on?(operation) ->
                rejected(operation_id, "invalid_operation")

              not valid_positive_integer?(value(operation, "amount_cents")) ->
                rejected(operation_id, "invalid_amount")

              true ->
                amount_cents = value(operation, "amount_cents")

                cond do
                  aggregate_held_funding(source_group) < amount_cents ->
                    rejected(operation_id, "transfer_exceeds_held_funding")

                  aggregate_outstanding_deposit(destination_group) < amount_cents ->
                    rejected(operation_id, "transfer_exceeds_outstanding")

                  true ->
                    source_group = ensure_room_accounting!(source_group) |> Repo.preload(:rooms)

                    destination_group =
                      ensure_room_accounting!(destination_group) |> Repo.preload(:rooms)

                    allocations = held_funding_allocations(source_group)

                    if Enum.sum(Enum.map(allocations, & &1.amount_cents)) < amount_cents do
                      raise "transfer allocation did not contain the held funding"
                    end

                    move_transfer_funding!(allocations, destination_group, amount_cents)

                    source =
                      update_group_totals!(source_group, source_group.revision + 1)

                    destination =
                      update_group_totals!(
                        destination_group,
                        destination_group.revision + 1
                      )

                    applied(operation_id, %{
                      "source_group_id" => source.group_id,
                      "destination_group_id" => destination.group_id,
                      "amount_cents" => amount_cents,
                      "source_outstanding_deposit_cents" => outstanding_deposit(source),
                      "destination_outstanding_deposit_cents" => outstanding_deposit(destination),
                      "source_revision" => source.revision,
                      "destination_revision" => destination.revision
                    })
                end
            end
        end
    end
  end

  defp check_expected_revision(operation, operation_id, group),
    do: check_expected_revision(operation, "expected_revision", operation_id, group)

  defp check_expected_revision(operation, key, operation_id, group) do
    case optional_value(operation, key) do
      :missing ->
        :ok

      {:present, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error,
           rejected(operation_id, "stale_revision", group.group_id, %{
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           })}
        end

      {:present, _invalid_revision} ->
        {:error, rejected(operation_id, "invalid_operation", group.group_id)}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_operation", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        amount_cents = value(operation, "amount_cents")
        allocate_cash!(group, operation_id, amount_cents)

        Repo.insert!(%CashPayment{
          payment_operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount_cents,
          held_cents: amount_cents,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        })

        updated_group = update_group_totals!(group, group.revision + 1)
        update_ledger!(cash_held_cents: amount_cents)

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        })
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, new_arrival_on} <- parse_date(operation, "new_arrival_on"),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)

          updated_group =
            group
            |> Changeset.change(
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            )
            |> Repo.update!()

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
            "policy_version" => policy_version(updated_group),
            "refundable_until" => refundable_until(updated_group),
            "revision" => updated_group.revision
          })
        else
          _ -> rejected(operation_id, "invalid_stay", group.group_id)
        end
    end
  end

  defp cancel_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, refund_method} <- refund_method(operation),
             refundable? <- refundable?(group, occurred_on),
             :ok <- available_refund_method(refundable?, refund_method) do
          active_room_ids =
            group
            |> ordered_rooms()
            |> Enum.filter(&room_status_active?/1)
            |> Enum.map(& &1.room_id)

          settlement =
            settle_selected_rooms(
              group,
              active_room_ids,
              operation_id,
              occurred_on,
              refundable?,
              refund_method
            )

          applied(operation_id, %{
            "group_id" => group.group_id,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => settlement.group.revision
          })
        else
          {:error, code} -> rejected(operation_id, code, group.group_id)
        end
    end
  end

  defp cancel_rooms(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, refund_method} <- refund_method(operation),
             refundable? <- refundable?(group, occurred_on),
             :ok <- available_refund_method(refundable?, refund_method),
             {:ok, room_ids} <- selected_room_ids(operation, group) do
          settlement =
            settle_selected_rooms(
              group,
              room_ids,
              operation_id,
              occurred_on,
              refundable?,
              refund_method
            )

          applied(operation_id, %{
            "group_id" => group.group_id,
            "cancelled_room_ids" => room_ids,
            "refunded_cents" => settlement.refunded_cents,
            "retained_cents" => settlement.retained_cents,
            "credit_issued_cents" => settlement.credit_issued_cents,
            "revision" => settlement.group.revision
          })
        else
          {:error, code} -> rejected(operation_id, code, group.group_id)
        end
    end
  end

  defp available_refund_method(false, @hotel_credit), do: {:error, "refund_method_not_available"}
  defp available_refund_method(_refundable?, _refund_method), do: :ok

  defp selected_room_ids(operation, group) do
    case value(operation, "room_ids") do
      room_ids when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &is_binary/1) and Enum.all?(room_ids, &(&1 != "")) and
             length(Enum.uniq(room_ids)) == length(room_ids) do
          active_ids =
            group
            |> ordered_rooms()
            |> Enum.filter(&room_status_active?/1)
            |> MapSet.new(& &1.room_id)

          if Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
            selected = MapSet.new(room_ids)

            {:ok,
             group
             |> ordered_rooms()
             |> Enum.filter(fn room -> MapSet.member?(selected, room.room_id) end)
             |> Enum.map(& &1.room_id)}
          else
            {:error, "invalid_rooms"}
          end
        else
          {:error, "invalid_rooms"}
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp settle_selected_rooms(
         group,
         room_ids,
         operation_id,
         occurred_on,
         refundable?,
         refund_method
       ) do
    cash_settlement =
      settle_cash_for_rooms!(
        group.group_id,
        room_ids,
        operation_id,
        occurred_on,
        refundable?,
        refund_method
      )

    settle_credit_for_rooms!(group.group_id, room_ids, occurred_on, refundable?)

    selected = MapSet.new(room_ids)

    group
    |> ordered_rooms()
    |> Enum.filter(&MapSet.member?(selected, &1.room_id))
    |> Enum.each(fn room ->
      room
      |> Changeset.change(status: @cancelled)
      |> Repo.update!()
    end)

    updated_group = update_group_totals!(group, group.revision + 1)

    %{
      group: updated_group,
      refunded_cents: cash_settlement.refunded_cents,
      retained_cents: cash_settlement.retained_cents,
      credit_issued_cents: cash_settlement.credit_issued_cents
    }
  end

  defp settle_cash_for_rooms!(
         group_id,
         room_ids,
         operation_id,
         occurred_on,
         refundable?,
         refund_method
       ) do
    held = @held

    allocations =
      from(a in CashAllocation,
        where: a.group_id == ^group_id and a.room_id in ^room_ids and a.disposition == ^held,
        order_by: [asc: a.id]
      )
      |> Repo.all()

    disposition = cash_settlement_disposition(refundable?, refund_method)
    cash_paid_cents = Enum.sum(Enum.map(allocations, & &1.amount_cents))

    Enum.each(allocations, fn allocation ->
      allocation
      |> Changeset.change(disposition: disposition)
      |> Repo.update!()

      if allocation.payment_operation_id do
        update_cash_payment!(
          allocation.payment_operation_id,
          Map.merge(
            %{held_cents: -allocation.amount_cents},
            disposition_increment(disposition, allocation.amount_cents)
          )
        )
      end
    end)

    ledger_changes =
      [cash_held_cents: -cash_paid_cents] ++
        case disposition do
          @refunded -> [cash_refunded_cents: cash_paid_cents]
          @retained -> [cash_retained_cents: cash_paid_cents]
          @converted -> [cash_converted_to_credit_cents: cash_paid_cents]
        end

    update_ledger!(ledger_changes)

    credit_issued_cents =
      if disposition == @converted do
        credit_from_cash(cash_paid_cents)
      else
        0
      end

    if credit_issued_cents > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group_guest_id!(group_id),
          source_operation_id: operation_id,
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 366),
          unrecovered_clawback_cents: 0
        })

      insert_credit_contributions!(lot.id, payment_contributors(allocations))
    end

    %{
      refunded_cents: if(disposition == @refunded, do: cash_paid_cents, else: 0),
      retained_cents: if(disposition == @retained, do: cash_paid_cents, else: 0),
      credit_issued_cents: credit_issued_cents
    }
  end

  defp settle_credit_for_rooms!(group_id, room_ids, occurred_on, refundable?) do
    allocations =
      from(a in CreditAllocation,
        join: lot in CreditLot,
        on: lot.id == a.credit_lot_id,
        where: a.group_id == ^group_id and a.room_id in ^room_ids,
        order_by: [asc: a.id],
        select: {a, lot}
      )
      |> Repo.all()

    Enum.each(allocations, fn {allocation, lot} ->
      if refundable? do
        restore_credit!(Repo.get!(CreditLot, lot.id), allocation.amount_cents, occurred_on)
      end

      Repo.delete!(allocation)
    end)

    refresh_credit_liability!()
  end

  defp cash_settlement_disposition(true, @cash), do: @refunded
  defp cash_settlement_disposition(true, @hotel_credit), do: @converted
  defp cash_settlement_disposition(false, @cash), do: @retained

  defp disposition_increment(@refunded, amount), do: %{refunded_cents: amount}
  defp disposition_increment(@retained, amount), do: %{retained_cents: amount}
  defp disposition_increment(@converted, amount), do: %{converted_to_credit_cents: amount}

  defp apply_hotel_credit(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_operation", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        {:ok, occurred_on} = parse_date(operation, "occurred_on")
        amount_cents = value(operation, "amount_cents")
        lots = available_credit_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
          rejected(operation_id, "insufficient_credit", group.group_id)
        else
          allocate_credit!(group, operation_id, lots, amount_cents)
          updated_group = update_group_totals!(group, group.revision + 1)
          refresh_credit_liability!()

          applied(operation_id, %{
            "group_id" => group.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding_deposit(updated_group),
            "revision" => updated_group.revision
          })
        end
    end
  end

  defp allocate_cash!(group, payment_operation_id, amount_cents) do
    {remaining, _rooms} =
      Enum.reduce(ordered_rooms(group), {amount_cents, []}, fn room, {remaining, rooms} ->
        capacity = room_outstanding(room)
        amount = if room_status_active?(room), do: min(capacity, remaining), else: 0

        if amount > 0 do
          room
          |> Changeset.change(cash_paid_cents: room_cash_paid(room) + amount)
          |> Repo.update!()

          Repo.insert!(%CashAllocation{
            group_id: group.group_id,
            room_id: room.room_id,
            payment_operation_id: payment_operation_id,
            amount_cents: amount,
            disposition: @held
          })
        end

        {remaining - amount, [room | rooms]}
      end)

    if remaining != 0 do
      raise "cash allocation did not fit the group deposit"
    end
  end

  defp allocate_credit!(group, operation_id, lots, amount_cents) do
    {remaining, _lots} =
      Enum.reduce(ordered_rooms(group), {amount_cents, lots}, fn room, {remaining, lots} ->
        room_capacity = room_outstanding(room)
        room_amount = if room_status_active?(room), do: min(room_capacity, remaining), else: 0

        {room_remaining, lots} =
          allocate_credit_to_room!(
            group.group_id,
            room,
            operation_id,
            lots,
            room_amount
          )

        allocated = room_amount - room_remaining

        if allocated > 0 do
          room
          |> Changeset.change(credit_paid_cents: room_credit_paid(room) + allocated)
          |> Repo.update!()
        end

        {remaining - room_amount + room_remaining, lots}
      end)

    if remaining != 0 do
      raise "credit allocation did not fit the group deposit"
    end
  end

  defp allocate_credit_to_room!(_group_id, _room, _operation_id, lots, 0), do: {0, lots}

  defp allocate_credit_to_room!(group_id, room, operation_id, [lot | rest], amount) do
    amount_from_lot = min(lot.remaining_cents, amount)

    lot
    |> Changeset.change(remaining_cents: lot.remaining_cents - amount_from_lot)
    |> Repo.update!()

    Repo.insert!(%CreditAllocation{
      group_id: group_id,
      room_id: room.room_id,
      funding_operation_id: operation_id,
      credit_lot_id: lot.id,
      amount_cents: amount_from_lot
    })

    next_lots =
      if amount_from_lot == lot.remaining_cents do
        rest
      else
        [%{lot | remaining_cents: lot.remaining_cents - amount_from_lot} | rest]
      end

    allocate_credit_to_room!(
      group_id,
      room,
      operation_id,
      next_lots,
      amount - amount_from_lot
    )
  end

  defp allocate_credit_to_room!(_group_id, _room, _operation_id, [], _amount),
    do: raise("credit allocation ran out of lots")

  defp held_funding_allocations(group) do
    active_room_ids =
      group
      |> ordered_rooms()
      |> Enum.filter(&room_status_active?/1)
      |> Enum.map(& &1.room_id)
      |> MapSet.new()

    operation_orders =
      Repo.all(from(o in OperationRecord, select: {o.operation_id, o.id}))
      |> Map.new()

    cash_allocations =
      from(a in CashAllocation,
        where: a.group_id == ^group.group_id and a.disposition == ^@held
      )
      |> Repo.all()
      |> Enum.filter(&MapSet.member?(active_room_ids, &1.room_id))
      |> Enum.map(fn allocation ->
        funding_allocation(
          :cash,
          allocation,
          allocation.payment_operation_id,
          operation_orders
        )
      end)

    credit_allocations =
      from(a in CreditAllocation, where: a.group_id == ^group.group_id)
      |> Repo.all()
      |> Enum.filter(&MapSet.member?(active_room_ids, &1.room_id))
      |> Enum.map(fn allocation ->
        funding_allocation(
          :credit,
          allocation,
          allocation.funding_operation_id,
          operation_orders
        )
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(fn allocation ->
      {allocation.operation_order, allocation.allocation_id, allocation.kind_order}
    end)
    |> Enum.reverse()
  end

  defp funding_allocation(kind, allocation, funding_operation_id, operation_orders) do
    %{
      kind: kind,
      allocation: allocation,
      amount_cents: allocation.amount_cents,
      operation_order: Map.get(operation_orders, funding_operation_id, 0),
      allocation_id: allocation.id,
      kind_order: if(kind == :cash, do: 0, else: 1)
    }
  end

  defp move_transfer_funding!(_allocations, _destination_group, 0), do: :ok

  defp move_transfer_funding!([funding | rest], destination_group, amount_remaining) do
    amount = min(funding.amount_cents, amount_remaining)

    allocate_transfer_funding!(funding, destination_group.group_id, amount)
    remove_source_funding!(funding, amount)

    if funding.kind == :cash do
      mark_cash_payment_transferred!(funding.allocation.payment_operation_id)
    end

    move_transfer_funding!(rest, destination_group, amount_remaining - amount)
  end

  defp move_transfer_funding!([], _destination_group, _amount_remaining),
    do: raise("transfer allocation did not contain the held funding")

  defp allocate_transfer_funding!(funding, destination_group_id, amount) do
    destination_rooms =
      load_rooms(destination_group_id)
      |> Enum.filter(&room_status_active?/1)

    {remaining, _rooms} =
      Enum.reduce_while(destination_rooms, {amount, []}, fn room, {remaining, rooms} ->
        room_amount = min(room_outstanding(room), remaining)

        if room_amount > 0 do
          increment_room_funding!(room, funding.kind, room_amount)
          insert_transfer_allocation!(funding, destination_group_id, room.room_id, room_amount)
        end

        remaining = remaining - room_amount

        if remaining == 0 do
          {:halt, {0, [room | rooms]}}
        else
          {:cont, {remaining, [room | rooms]}}
        end
      end)

    if remaining != 0 do
      raise "transfer funding did not fit the destination deposit"
    end
  end

  defp insert_transfer_allocation!(
         %{kind: :cash, allocation: allocation},
         destination_group_id,
         room_id,
         amount
       ) do
    Repo.insert!(%CashAllocation{
      group_id: destination_group_id,
      room_id: room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount,
      disposition: @held
    })
  end

  defp insert_transfer_allocation!(
         %{kind: :credit, allocation: allocation},
         destination_group_id,
         room_id,
         amount
       ) do
    Repo.insert!(%CreditAllocation{
      group_id: destination_group_id,
      room_id: room_id,
      funding_operation_id: allocation.funding_operation_id,
      credit_lot_id: allocation.credit_lot_id,
      amount_cents: amount
    })
  end

  defp remove_source_funding!(%{kind: :cash, allocation: allocation}, amount) do
    remove_allocation_amount!(allocation, amount)
    decrement_room_funding!(allocation.group_id, allocation.room_id, :cash, amount)
  end

  defp remove_source_funding!(%{kind: :credit, allocation: allocation}, amount) do
    remove_allocation_amount!(allocation, amount)
    decrement_room_funding!(allocation.group_id, allocation.room_id, :credit, amount)
  end

  defp remove_allocation_amount!(allocation, amount) do
    new_amount = allocation.amount_cents - amount

    if new_amount == 0 do
      Repo.delete!(allocation)
    else
      allocation
      |> Changeset.change(amount_cents: new_amount)
      |> Repo.update!()
    end
  end

  defp increment_room_funding!(room, :cash, amount) do
    room
    |> Changeset.change(cash_paid_cents: room_cash_paid(room) + amount)
    |> Repo.update!()
  end

  defp increment_room_funding!(room, :credit, amount) do
    room
    |> Changeset.change(credit_paid_cents: room_credit_paid(room) + amount)
    |> Repo.update!()
  end

  defp decrement_room_funding!(group_id, room_id, :cash, amount) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Changeset.change(cash_paid_cents: room_cash_paid(room) - amount)
    |> Repo.update!()
  end

  defp decrement_room_funding!(group_id, room_id, :credit, amount) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Changeset.change(credit_paid_cents: room_credit_paid(room) - amount)
    |> Repo.update!()
  end

  defp mark_cash_payment_transferred!(nil), do: :ok

  defp mark_cash_payment_transferred!(payment_operation_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      nil ->
        :ok

      %{transfer_participated: true} ->
        :ok

      payment ->
        payment
        |> Changeset.change(transfer_participated: true)
        |> Repo.update!()
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    from(a in CashAllocation,
      where:
        a.payment_operation_id == ^payment_operation_id and
          a.disposition == ^@held and a.amount_cents > 0,
      group_by: a.group_id,
      select: {a.group_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp apply_payment_operation(
         type,
         operation,
         operation_id,
         payment_operation_id,
         record
       ) do
    with {:ok, group_id} <- applied_payment_group(record),
         %Group{} = group <- Repo.get(Group, group_id) do
      group = ensure_room_accounting!(group) |> Repo.preload(:rooms)
      payment = ensure_cash_payment!(record, payment_operation_id, group_id)

      case check_expected_revision(operation, operation_id, group) do
        {:error, result} ->
          result

        :ok ->
          if valid_occurred_on?(operation) do
            case type do
              "reduce_cash_payment" ->
                reduce_cash_payment(operation, operation_id, payment_operation_id, group, payment)

              "charge_back_payment" ->
                charge_back_payment(operation_id, payment_operation_id, group, payment)
            end
          else
            rejected(operation_id, "invalid_operation", group.group_id)
          end
      end
    else
      {:error, _code} -> rejected(operation_id, payment_operation_error(type))
      nil -> rejected(operation_id, payment_operation_error(type))
    end
  end

  defp payment_operation_error("reduce_cash_payment"), do: "payment_not_reducible"
  defp payment_operation_error("charge_back_payment"), do: "payment_not_chargeable"

  defp applied_payment_group(record) do
    if record.type == "record_cash_payment" and value(record.result, "status") == "applied" do
      required_result_identifier(record.result, "group_id")
    else
      {:error, "not_an_applied_cash_payment"}
    end
  end

  defp reduce_cash_payment(operation, operation_id, payment_operation_id, group, payment) do
    cond do
      payment.held_cents <= 0 ->
        rejected(operation_id, "payment_not_reducible", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > payment.held_cents ->
        rejected(operation_id, "reduction_exceeds_held_cash", group.group_id)

      true ->
        amount_cents = value(operation, "amount_cents")
        affected_group_ids = remove_held_cash!(payment_operation_id, amount_cents)

        update_cash_payment!(payment_operation_id, %{
          held_cents: -amount_cents,
          reduced_cents: amount_cents
        })

        update_ledger!(cash_held_cents: -amount_cents, cash_reduced_cents: amount_cents)
        updated_groups = bump_group_revisions!(affected_group_ids, group.group_id)
        updated_group = Map.fetch!(updated_groups, group.group_id)

        applied(operation_id, %{
          "payment_operation_id" => payment_operation_id,
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        })
    end
  end

  defp charge_back_payment(operation_id, payment_operation_id, group, payment) do
    if payment.held_cents + payment.refunded_cents + payment.retained_cents +
         payment.converted_to_credit_cents <= 0 or payment.charged_back_cents > 0 do
      rejected(operation_id, "payment_not_chargeable", group.group_id)
    else
      held_cents = payment.held_cents
      refunded_cents = payment.refunded_cents
      retained_cents = payment.retained_cents
      converted_cents = payment.converted_to_credit_cents
      charged_back_cents = held_cents + refunded_cents + retained_cents + converted_cents

      affected_group_ids = charge_back_allocations!(payment_operation_id)
      ensure_historical_credit_contributions!(group.group_id, payment)
      revoke_credit_entitlements!(payment_operation_id)

      update_cash_payment!(payment_operation_id, %{
        held_cents: -held_cents,
        refunded_cents: -refunded_cents,
        retained_cents: -retained_cents,
        converted_to_credit_cents: -converted_cents,
        charged_back_cents: charged_back_cents
      })

      update_ledger!(
        cash_held_cents: -held_cents,
        cash_refunded_cents: -refunded_cents,
        cash_retained_cents: -retained_cents,
        cash_converted_to_credit_cents: -converted_cents,
        cash_charged_back_cents: charged_back_cents
      )

      refresh_credit_liability!()
      updated_groups = bump_group_revisions!(affected_group_ids, group.group_id)
      updated_group = Map.fetch!(updated_groups, group.group_id)

      applied(operation_id, %{
        "payment_operation_id" => payment_operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => charged_back_cents,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    end
  end

  defp remove_held_cash!(payment_operation_id, amount_cents) do
    held = @held

    allocations =
      from(a in CashAllocation,
        where: a.payment_operation_id == ^payment_operation_id and a.disposition == ^held,
        order_by: [desc: a.id]
      )
      |> Repo.all()

    {remaining, affected_group_ids} =
      Enum.reduce_while(allocations, {amount_cents, MapSet.new()}, fn allocation,
                                                                      {remaining, affected} ->
        amount = min(remaining, allocation.amount_cents)
        new_amount = allocation.amount_cents - amount

        if new_amount == 0 do
          Repo.delete!(allocation)
        else
          allocation
          |> Changeset.change(amount_cents: new_amount)
          |> Repo.update!()
        end

        decrement_room_cash!(allocation.group_id, allocation.room_id, amount)
        remaining = remaining - amount
        affected = MapSet.put(affected, allocation.group_id)

        if remaining == 0, do: {:halt, {0, affected}}, else: {:cont, {remaining, affected}}
      end)

    if remaining != 0 do
      raise "cash allocation did not contain the held payment"
    end

    MapSet.to_list(affected_group_ids)
  end

  defp charge_back_allocations!(payment_operation_id) do
    held = @held
    refunded = @refunded
    retained = @retained
    converted = @converted

    allocations =
      from(a in CashAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and
            a.disposition in [^held, ^refunded, ^retained, ^converted],
        order_by: [asc: a.id]
      )
      |> Repo.all()

    Enum.reduce(allocations, MapSet.new(), fn allocation, affected_group_ids ->
      if allocation.disposition == @held do
        decrement_room_cash!(allocation.group_id, allocation.room_id, allocation.amount_cents)
      end

      allocation
      |> Changeset.change(disposition: @charged_back)
      |> Repo.update!()

      if allocation.disposition == @held do
        MapSet.put(affected_group_ids, allocation.group_id)
      else
        affected_group_ids
      end
    end)
  end

  defp decrement_room_cash!(group_id, room_id, amount_cents) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Changeset.change(cash_paid_cents: room_cash_paid(room) - amount_cents)
    |> Repo.update!()
  end

  defp update_cash_payment!(payment_operation_id, increments) do
    payment = Repo.get!(CashPayment, payment_operation_id)

    values =
      Enum.reduce(increments, %{}, fn {field, increment}, acc ->
        Map.put(acc, field, Map.fetch!(payment, field) + increment)
      end)

    payment
    |> Changeset.change(values)
    |> Repo.update!()
  end

  defp revoke_credit_entitlements!(payment_operation_id) do
    contributions =
      from(c in CreditLotContribution,
        where: c.payment_operation_id == ^payment_operation_id,
        order_by: [asc: c.id]
      )
      |> Repo.all()

    Enum.each(contributions, fn contribution ->
      amount = contribution.entitlement_cents - contribution.clawed_back_cents
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      removed_available = min(amount, lot.remaining_cents)
      unrecovered = amount - removed_available

      lot
      |> Changeset.change(
        remaining_cents: lot.remaining_cents - removed_available,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered
      )
      |> Repo.update!()

      contribution
      |> Changeset.change(clawed_back_cents: contribution.clawed_back_cents + amount)
      |> Repo.update!()
    end)
  end

  defp restore_credit!(lot, amount_cents, occurred_on) do
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered, amount_cents)
    excess = amount_cents - absorbed

    available_excess =
      if excess > 0 and Date.compare(lot.expires_on, occurred_on) == :gt, do: excess, else: 0

    lot
    |> Changeset.change(
      remaining_cents: lot.remaining_cents + available_excess,
      unrecovered_clawback_cents: unrecovered - absorbed
    )
    |> Repo.update!()
  end

  defp payment_contributors(allocations) do
    Enum.reduce(allocations, [], fn allocation, contributors ->
      payment_id = allocation.payment_operation_id

      case List.keyfind(contributors, payment_id, 0) do
        nil ->
          contributors ++ [{payment_id, allocation.amount_cents}]

        {^payment_id, previous} ->
          List.keystore(
            contributors,
            payment_id,
            0,
            {payment_id, previous + allocation.amount_cents}
          )
      end
    end)
  end

  defp insert_credit_contributions!(lot_id, contributors) do
    Enum.reduce(contributors, 0, fn {payment_id, amount}, running_cash ->
      next_cash = running_cash + amount
      entitlement = credit_from_cash(next_cash) - credit_from_cash(running_cash)

      if entitlement > 0 do
        Repo.insert!(%CreditLotContribution{
          credit_lot_id: lot_id,
          payment_operation_id: payment_id,
          entitlement_cents: entitlement,
          clawed_back_cents: 0
        })
      end

      next_cash
    end)

    :ok
  end

  defp ensure_cash_payment!(record, payment_operation_id, group_id) do
    case Repo.get(CashPayment, payment_operation_id) do
      nil ->
        amount = value(record.result, "amount_cents")
        payment = historical_payment_state(record, group_id, amount)

        Repo.insert!(payment)

      payment ->
        payment
    end
  end

  defp reconciliation_payment(record, group_id) do
    case Repo.get(CashPayment, record.operation_id) do
      nil ->
        case value(record.result, "amount_cents") do
          amount when is_integer(amount) ->
            {:ok, historical_payment_state(record, group_id, amount)}

          _ ->
            {:error, :payment_not_reconcilable}
        end

      payment ->
        {:ok, payment}
    end
  end

  defp group_active?(group_id) do
    case Repo.get(Group, group_id) do
      %Group{status: @active} -> true
      _ -> false
    end
  end

  defp historical_payment_state(record, group_id, amount) do
    base = [
      payment_operation_id: record.operation_id,
      group_id: group_id,
      recorded_cents: amount,
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    ]

    fields =
      if group_active?(group_id) do
        [held_cents: amount]
      else
        case historical_cancellation(group_id) do
          nil -> [held_cents: amount]
          cancellation -> historical_settlement_field(cancellation, amount)
        end
      end

    struct(CashPayment, Keyword.merge(base, fields))
  end

  defp historical_cancellation(group_id) do
    Repo.all(from(o in OperationRecord, order_by: [asc: o.id]))
    |> Enum.filter(fn record ->
      record.type in ["cancel_group", "cancel_rooms"] and
        value(record.result, "status") == "applied" and
        value(record.result, "group_id") == group_id
    end)
    |> List.last()
  end

  defp historical_settlement_field(record, amount) do
    refunded_cents = value(record.result, "refunded_cents") || 0
    retained_cents = value(record.result, "retained_cents") || 0
    credit_issued_cents = value(record.result, "credit_issued_cents") || 0

    cond do
      refunded_cents > 0 -> [refunded_cents: amount]
      retained_cents > 0 -> [retained_cents: amount]
      credit_issued_cents > 0 -> [converted_to_credit_cents: amount]
      true -> [held_cents: amount]
    end
  end

  defp ensure_historical_credit_contributions!(group_id, payment) do
    if payment.converted_to_credit_cents > 0 and
         Repo.aggregate(
           from(c in CreditLotContribution,
             where: c.payment_operation_id == ^payment.payment_operation_id
           ),
           :count,
           :id
         ) == 0 do
      case historical_cancellation(group_id) do
        nil ->
          :ok

        cancellation ->
          lot = Repo.get_by(CreditLot, source_operation_id: cancellation.operation_id)

          if lot do
            records =
              durable_funding_records(group_id)
              |> Enum.filter(&(&1.type == "record_cash_payment"))

            recorded_cash = Enum.sum(Enum.map(records, &result_amount/1))
            group = Repo.get!(Group, group_id)
            legacy_cash = max(cash_paid_total(group) - recorded_cash, 0)

            insert_credit_contributions!(
              lot.id,
              [{nil, legacy_cash} | Enum.map(records, &{&1.operation_id, result_amount(&1)})]
              |> Enum.reject(fn {_payment_id, amount} -> amount == 0 end)
            )
          end
      end
    end
  end

  defp required_result_identifier(result, key) do
    case value(result, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp group_guest_id!(group_id), do: Repo.get!(Group, group_id).guest_id

  defp ensure_room_accounting!(group) do
    rooms = Repo.preload(group, :rooms).rooms

    if group.status == @active and room_accounting_needed?(group, rooms) do
      backfill_room_accounting!(group, rooms)
    end

    group
  end

  defp ensure_all_room_accounting! do
    Repo.all(Group)
    |> Enum.each(&ensure_room_accounting!/1)

    :ok
  end

  defp room_accounting_needed?(group, rooms) do
    active_rooms = Enum.filter(rooms, &room_status_active?/1)

    Enum.any?(rooms, fn room ->
      is_nil(room.status) or is_nil(room.deposit_due_cents) or is_nil(room.cash_paid_cents) or
        is_nil(room.credit_paid_cents)
    end) or
      Enum.sum(Enum.map(active_rooms, &room_cash_paid/1)) != cash_paid_total(group) or
      Enum.sum(Enum.map(active_rooms, &room_credit_paid/1)) != credit_paid_total(group)
  end

  defp backfill_room_accounting!(group, rooms) do
    records = durable_funding_records(group.group_id)
    cash_records = Enum.filter(records, &(&1.type == "record_cash_payment"))
    credit_records = Enum.filter(records, &(&1.type == "apply_hotel_credit"))
    recorded_cash = Enum.sum(Enum.map(cash_records, &result_amount/1))
    recorded_credit = Enum.sum(Enum.map(credit_records, &result_amount/1))
    legacy_cash = max(cash_paid_total(group) - recorded_cash, 0)
    legacy_credit = max(credit_paid_total(group) - recorded_credit, 0)

    Enum.each(cash_records, fn record ->
      amount = result_amount(record)

      unless Repo.get(CashPayment, record.operation_id) do
        Repo.insert!(%CashPayment{
          payment_operation_id: record.operation_id,
          group_id: group.group_id,
          recorded_cents: amount,
          held_cents: amount,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        })
      end
    end)

    existing_credit_segments =
      from(a in CreditAllocation,
        where: a.group_id == ^group.group_id,
        order_by: [asc: a.id],
        select: {a.credit_lot_id, a.amount_cents}
      )
      |> Repo.all()

    Repo.delete_all(from(a in CashAllocation, where: a.group_id == ^group.group_id))
    Repo.delete_all(from(a in CreditAllocation, where: a.group_id == ^group.group_id))

    Enum.each(rooms, fn room ->
      room
      |> Changeset.change(
        status: room.status || @active,
        deposit_due_cents: room_deposit_due(room, group),
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    funding_events =
      [{:cash, nil, legacy_cash}, {:credit, nil, legacy_credit}] ++
        Enum.map(records, fn record ->
          case record.type do
            "record_cash_payment" -> {:cash, record.operation_id, result_amount(record)}
            "apply_hotel_credit" -> {:credit, record.operation_id, result_amount(record)}
          end
        end)

    Enum.reduce(funding_events, existing_credit_segments, fn
      {:cash, payment_id, amount}, segments ->
        allocate_backfill_cash!(group, payment_id, amount)
        segments

      {:credit, funding_operation_id, amount}, segments ->
        allocate_backfill_credit!(group, funding_operation_id, amount, segments)
    end)

    :ok
  end

  defp durable_funding_records(group_id) do
    Repo.all(from(o in OperationRecord, order_by: [asc: o.id]))
    |> Enum.filter(fn record ->
      record.type in ["record_cash_payment", "apply_hotel_credit"] and
        value(record.result, "status") == "applied" and
        value(record.result, "group_id") == group_id
    end)
  end

  defp allocate_backfill_cash!(_group, _payment_id, 0), do: :ok

  defp allocate_backfill_cash!(group, payment_id, amount) do
    rooms = load_rooms(group.group_id)

    {remaining, _} =
      Enum.reduce(rooms, {amount, nil}, fn room, {remaining, _} ->
        room_amount =
          if room_status_active?(room), do: min(room_outstanding(room), remaining), else: 0

        if room_amount > 0 do
          room
          |> Changeset.change(cash_paid_cents: room_cash_paid(room) + room_amount)
          |> Repo.update!()

          Repo.insert!(%CashAllocation{
            group_id: group.group_id,
            room_id: room.room_id,
            payment_operation_id: payment_id,
            amount_cents: room_amount,
            disposition: @held
          })
        end

        {remaining - room_amount, nil}
      end)

    if remaining != 0, do: raise("legacy cash allocation did not fit")
  end

  defp allocate_backfill_credit!(_group, _operation_id, 0, segments), do: segments

  defp allocate_backfill_credit!(group, operation_id, amount, segments) do
    rooms = load_rooms(group.group_id)

    {remaining, segments} =
      Enum.reduce(rooms, {amount, segments}, fn room, {remaining, segments} ->
        room_amount =
          if room_status_active?(room), do: min(room_outstanding(room), remaining), else: 0

        {room_remaining, segments} =
          allocate_backfill_credit_to_room!(
            group.group_id,
            room,
            operation_id,
            room_amount,
            segments
          )

        allocated = room_amount - room_remaining

        if allocated > 0 do
          room
          |> Changeset.change(credit_paid_cents: room_credit_paid(room) + allocated)
          |> Repo.update!()
        end

        {remaining - room_amount + room_remaining, segments}
      end)

    if remaining != 0, do: raise("legacy credit allocation did not fit")
    segments
  end

  defp allocate_backfill_credit_to_room!(_group_id, _room, _operation_id, 0, segments),
    do: {0, segments}

  defp allocate_backfill_credit_to_room!(group_id, room, operation_id, amount, [
         {lot_id, segment_amount} | rest
       ]) do
    amount_from_segment = min(amount, segment_amount)

    Repo.insert!(%CreditAllocation{
      group_id: group_id,
      room_id: room.room_id,
      funding_operation_id: operation_id,
      credit_lot_id: lot_id,
      amount_cents: amount_from_segment
    })

    next_segments =
      if amount_from_segment == segment_amount do
        rest
      else
        [{lot_id, segment_amount - amount_from_segment} | rest]
      end

    allocate_backfill_credit_to_room!(
      group_id,
      room,
      operation_id,
      amount - amount_from_segment,
      next_segments
    )
  end

  defp allocate_backfill_credit_to_room!(_group_id, _room, _operation_id, _amount, []),
    do: raise("legacy credit allocation had no source lot")

  defp load_rooms(group_id) do
    from(r in Room, where: r.group_id == ^group_id, order_by: [asc: r.position])
    |> Repo.all()
  end

  defp aggregate_held_funding(group), do: group.deposit_paid_cents || 0

  defp aggregate_outstanding_deposit(group) do
    max((group.deposit_due_cents || 0) - (group.deposit_paid_cents || 0), 0)
  end

  defp bump_group_revisions!(affected_group_ids, addressed_group_id) do
    [addressed_group_id | Enum.to_list(affected_group_ids)]
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn group_id, updated_groups ->
      group = Repo.get!(Group, group_id)
      updated_group = update_group_totals!(group, group.revision + 1)
      Map.put(updated_groups, group_id, updated_group)
    end)
  end

  defp update_group_totals!(group, revision) do
    rooms = load_rooms(group.group_id)
    totals = active_room_totals(group, rooms)

    updated_group =
      group
      |> Changeset.change(
        lodging_total_cents: totals.lodging_total_cents,
        deposit_due_cents: totals.deposit_due_cents,
        deposit_paid_cents: totals.deposit_paid_cents,
        cash_paid_cents: totals.cash_paid_cents,
        credit_paid_cents: totals.credit_paid_cents,
        revision: revision,
        status: if(Enum.any?(rooms, &room_status_active?/1), do: @active, else: @cancelled)
      )
      |> Repo.update!()

    %{updated_group | rooms: rooms}
  end

  defp active_room_totals(group, rooms) do
    active_rooms = Enum.filter(rooms, &room_status_active?/1)
    nights = Date.diff(group.departure_on, group.arrival_on)

    %{
      lodging_total_cents: Enum.sum(Enum.map(active_rooms, &(nights * &1.nightly_rate_cents))),
      deposit_due_cents: Enum.sum(Enum.map(active_rooms, &room_deposit_due(&1, group))),
      deposit_paid_cents:
        Enum.sum(Enum.map(active_rooms, &(room_cash_paid(&1) + room_credit_paid(&1)))),
      cash_paid_cents: Enum.sum(Enum.map(active_rooms, &room_cash_paid/1)),
      credit_paid_cents: Enum.sum(Enum.map(active_rooms, &room_credit_paid/1))
    }
  end

  defp outstanding_deposit(group) do
    totals = active_room_totals(group, ordered_rooms(group))
    totals.deposit_due_cents - totals.deposit_paid_cents
  end

  defp ordered_rooms(group), do: Enum.sort_by(group.rooms || [], & &1.position)

  defp room_status_active?(room), do: (room.status || @active) == @active
  defp room_cash_paid(room), do: room.cash_paid_cents || 0
  defp room_credit_paid(room), do: room.credit_paid_cents || 0

  defp room_outstanding(room),
    do: max((room.deposit_due_cents || 0) - room_cash_paid(room) - room_credit_paid(room), 0)

  defp room_deposit_due(room, group) do
    room.deposit_due_cents ||
      deposit_for(
        group.rate_plan,
        Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents
      )
  end

  defp cash_paid_total(group), do: group.cash_paid_cents || group.deposit_paid_cents || 0
  defp credit_paid_total(group), do: group.credit_paid_cents || 0

  defp refundable?(group, occurred_on) do
    case policy_window(policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(group) do
    case policy_window(policy_version(group)) do
      nil -> nil
      window -> Date.to_iso8601(Date.add(group.arrival_on, -window))
    end
  end

  defp available_credit_lots(guest_id, on) do
    from(lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Repo.all()
  end

  defp credit_liability_as_of(on) do
    available_cents =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^on,
        select: lot.remaining_cents
      )
      |> Repo.all()
      |> Enum.sum()

    applied_cents =
      from(a in CreditAllocation,
        join: group in Group,
        on: group.group_id == a.group_id,
        where: group.status == @active,
        select: a.amount_cents
      )
      |> Repo.all()
      |> Enum.sum()

    available_cents + applied_cents
  end

  defp credit_shortfall_cents do
    applied_by_lot =
      from(a in CreditAllocation,
        join: group in Group,
        on: group.group_id == a.group_id,
        where: group.status == @active,
        group_by: a.credit_lot_id,
        select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    from(lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.sum_by(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end

  defp refresh_credit_liability! do
    ledger = Repo.get!(Ledger, 1)

    ledger
    |> Changeset.change(
      credit_liability_cents: credit_liability_as_of(Date.utc_today()),
      credit_shortfall_cents: credit_shortfall_cents()
    )
    |> Repo.update!()
  end

  defp update_ledger!(increments) do
    ledger = Repo.get!(Ledger, 1)

    updated_values =
      Enum.reduce(increments, %{}, fn {field, increment}, values ->
        Map.put(values, field, Map.fetch!(ledger, field) + increment)
      end)

    ledger
    |> Changeset.change(updated_values)
    |> Repo.update!()
  end

  defp serialize_group(group) do
    rooms = ordered_rooms(group)
    totals = active_room_totals(group, rooms)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" => Enum.map(rooms, &serialize_room/1),
      "lodging_total_cents" => totals.lodging_total_cents,
      "deposit_due_cents" => totals.deposit_due_cents,
      "deposit_paid_cents" => totals.deposit_paid_cents,
      "cash_paid_cents" => totals.cash_paid_cents,
      "credit_paid_cents" => totals.credit_paid_cents,
      "outstanding_deposit_cents" => totals.deposit_due_cents - totals.deposit_paid_cents
    }
  end

  defp serialize_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status || @active,
      "deposit_due_cents" => room.deposit_due_cents || 0,
      "cash_paid_cents" => room_cash_paid(room),
      "credit_paid_cents" => room_credit_paid(room)
    }
  end

  defp serialize_credit_lot(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, group_id \\ nil, extra \\ []) do
    base = %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    base = if group_id, do: Map.put(base, "group_id", group_id), else: base
    Enum.into(extra, base)
  end

  defp operation_type(operation) do
    case value(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp equivalent_payload?(left, right),
    do: canonical_payload(left) == canonical_payload(right)

  defp canonical_payload(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {canonical_key(key), canonical_payload(nested_value)}
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp canonical_payload(value) when is_list(value),
    do: Enum.map(value, &canonical_payload/1)

  defp canonical_payload(value), do: value

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: inspect(key)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> value_for_atom_key(map, key)
    end
  end

  defp value(_map, _key), do: nil

  defp optional_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      atom_key_exists?(map, key) -> {:present, Map.get(map, String.to_existing_atom(key))}
      true -> :missing
    end
  end

  defp value_for_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp atom_key_exists?(map, key) do
    Map.has_key?(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> false
  end

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(operation, key) do
    case value(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp parse_reporting_date(operation) do
    case value(operation, "starts_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_reporting_date"}
        end

      _ ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation, "occurred_on"))

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(operation) do
    case value(operation, "rate_plan") do
      @flexible -> {:ok, @flexible}
      @advance_purchase -> {:ok, @advance_purchase}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp validate_rooms(operation, departure_on, arrival_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    case value(operation, "rooms") do
      rooms when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.reduce_while({:ok, MapSet.new(), []}, fn room, {:ok, ids, acc} ->
          with {:ok, room_id} <- required_identifier(room, "room_id"),
               {:ok, nightly_rate_cents} <- positive_room_rate(room),
               false <- MapSet.member?(ids, room_id) do
            lodging_cents = nights * nightly_rate_cents
            deposit_cents = deposit_for(rate_plan, lodging_cents)

            {:cont,
             {:ok, MapSet.put(ids, room_id),
              [
                %{
                  room_id: room_id,
                  nightly_rate_cents: nightly_rate_cents,
                  lodging_cents: lodging_cents,
                  deposit_cents: deposit_cents
                }
                | acc
              ]}}
          else
            _ -> {:halt, {:error, "invalid_rooms"}}
          end
        end)
        |> case do
          {:ok, _ids, rooms} -> {:ok, Enum.reverse(rooms)}
          {:error, code} -> {:error, code}
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(room) when is_map(room) do
    case value(room, "nightly_rate_cents") do
      rate when is_integer(rate) and rate > 0 -> {:ok, rate}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(_room), do: {:error, "invalid_rooms"}

  defp deposit_for(@advance_purchase, lodging_cents), do: lodging_cents
  defp deposit_for(@flexible, lodging_cents), do: rounded_percentage(lodging_cents, 20)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: @flex_14, else: @flex_30
  end

  defp policy_version(group) do
    group.policy_version || policy_version_for(group.rate_plan, group.booked_on)
  end

  defp policy_window(@flex_14), do: 14
  defp policy_window(@flex_30), do: 30
  defp policy_window(@advance_nonrefundable), do: nil

  defp valid_positive_integer?(amount), do: is_integer(amount) and amount > 0

  defp refund_method(operation) do
    case optional_value(operation, "refund_method") do
      :missing -> {:ok, @cash}
      {:present, @cash} -> {:ok, @cash}
      {:present, @hotel_credit} -> {:ok, @hotel_credit}
      {:present, _invalid_method} -> {:error, "invalid_operation"}
    end
  end

  defp credit_from_cash(cash_cents), do: cash_cents + rounded_percentage(cash_cents, 10)

  defp rounded_percentage(amount_cents, percentage),
    do: div(amount_cents * percentage + 50, 100)

  defp result_amount(record), do: value(record.result, "amount_cents") || 0
end
