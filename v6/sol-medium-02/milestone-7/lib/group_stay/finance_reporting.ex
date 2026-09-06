defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable inception snapshots and append-only movements for daily finance reports."

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditLot}

  alias GroupStay.Finance.{
    CashMovement,
    CashOpeningBalance,
    CreditLotEvent,
    CreditMovement,
    CreditOpeningLot,
    PeriodClose,
    ReportingSetting
  }

  alias GroupStay.Groups.Group
  alias GroupStay.PartnerOperation
  alias GroupStay.Repo

  @cash_state_fields ~w(held refunded retained converted)a

  def setting, do: Repo.one(from setting in ReportingSetting, limit: 1)

  def latest_close do
    Repo.one(from close in PeriodClose, order_by: [desc: close.period_end_on], limit: 1)
  end

  def snapshot do
    %{cash: cash_snapshot(), credit_lots: credit_lot_snapshot()}
  end

  def start_reporting(operation, starts_on) do
    if setting() do
      {:error, :reporting_already_started}
    else
      partner_operation =
        Repo.get_by!(PartnerOperation, operation_id: operation["operation_id"])

      state = snapshot()

      opening_lots =
        state.credit_lots
        |> Enum.map(fn {lot_id, lot} ->
          available =
            if Date.compare(lot.expires_on, starts_on) in [:eq, :gt], do: lot.available, else: 0

          {lot_id, lot, available}
        end)
        |> Enum.filter(fn {_lot_id, lot, available} -> available > 0 or lot.applied > 0 end)

      liability =
        Enum.sum(
          Enum.map(opening_lots, fn {_lot_id, lot, available} -> available + lot.applied end)
        )

      Repo.insert!(
        ReportingSetting.changeset(%ReportingSetting{}, %{
          singleton: 1,
          starts_on: starts_on,
          partner_operation_id: partner_operation.id,
          opening_credit_liability_cents: liability
        })
      )

      state.cash
      |> Enum.filter(fn {_property_id, values} -> values.held > 0 end)
      |> Enum.each(fn {property_id, values} ->
        Repo.insert!(
          CashOpeningBalance.changeset(%CashOpeningBalance{}, %{
            property_id: property_id,
            opening_held_cents: values.held
          })
        )
      end)

      Enum.each(opening_lots, fn {lot_id, lot, available} ->
        Repo.insert!(
          CreditOpeningLot.changeset(%CreditOpeningLot{}, %{
            credit_lot_id: lot_id,
            expires_on: lot.expires_on,
            available_cents: available,
            applied_cents: lot.applied
          })
        )
      end)

      :ok
    end
  end

  def close_period(operation, period_end_on) do
    with %ReportingSetting{} = setting <- setting(),
         true <- Date.compare(period_end_on, setting.starts_on) in [:eq, :gt],
         true <- later_than_latest_close?(period_end_on) do
      partner_operation =
        Repo.get_by!(PartnerOperation, operation_id: operation["operation_id"])

      Repo.insert!(
        PeriodClose.changeset(%PeriodClose{}, %{
          period_end_on: period_end_on,
          partner_operation_id: partner_operation.id
        })
      )

      :ok
    else
      _ -> {:error, :invalid_period}
    end
  end

  def record_operation(partner_operation, operation, result, setting, before_state) do
    {posting_on, late_adjustment} = posting_date(operation["occurred_on"], setting.starts_on)
    after_state = snapshot()

    record_cash_movements(
      partner_operation,
      operation["type"],
      posting_on,
      late_adjustment,
      before_state.cash,
      after_state.cash
    )

    record_credit_movements(
      partner_operation,
      operation,
      result,
      posting_on,
      late_adjustment,
      before_state.credit_lots,
      after_state.credit_lots
    )

    record_credit_lot_events(
      partner_operation,
      posting_on,
      before_state.credit_lots,
      after_state.credit_lots
    )
  end

  def daily_report(date) do
    case setting() do
      nil -> {:error, :report_not_available}
      setting when date < setting.starts_on -> {:error, :report_not_available}
      setting -> {:ok, build_report(setting, date)}
    end
  end

  defp cash_snapshot do
    Repo.all(
      from group in Group,
        group_by: group.property_id,
        select: {
          group.property_id,
          %{
            held:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            refunded: coalesce(sum(group.refunded_cents), 0),
            retained: coalesce(sum(group.retained_cents), 0),
            converted: coalesce(sum(group.cash_converted_to_credit_cents), 0)
          }
        }
    )
    |> Map.new()
  end

  defp credit_lot_snapshot do
    Repo.all(
      from lot in CreditLot,
        left_join: application in CreditApplication,
        on: application.credit_lot_id == lot.id and application.status == "active",
        group_by: lot.id,
        select: {
          lot.id,
          %{
            available: lot.remaining_cents,
            applied: coalesce(sum(application.amount_cents), 0),
            clawback: lot.unrecovered_clawback_cents,
            expires_on: lot.expires_on
          }
        }
    )
    |> Map.new()
  end

  defp posting_date(value, starts_on) do
    {:ok, occurred_on} = Date.from_iso8601(value)
    close = latest_close()
    latest_cutoff = close && close.period_end_on
    first_open_on = if latest_cutoff, do: Date.add(latest_cutoff, 1), else: starts_on

    posting_on = Enum.max_by([occurred_on, starts_on, first_open_on], &Date.to_gregorian_days/1)
    {posting_on, latest_cutoff != nil and Date.compare(occurred_on, first_open_on) == :lt}
  end

  defp record_cash_movements(
         partner_operation,
         type,
         posting_on,
         late_adjustment,
         before,
         current
       ) do
    properties = (Map.keys(before) ++ Map.keys(current)) |> Enum.uniq()

    Enum.each(properties, fn property_id ->
      old = Map.get(before, property_id, empty_cash_state())
      new = Map.get(current, property_id, empty_cash_state())
      movement = classify_cash(type, old, new)

      if any_nonzero?(movement) do
        attrs =
          movement
          |> Map.merge(%{
            partner_operation_id: partner_operation.id,
            posting_on: posting_on,
            property_id: property_id,
            late_adjustment: late_adjustment
          })

        Repo.insert!(CashMovement.changeset(%CashMovement{}, attrs))
      end
    end)
  end

  defp classify_cash("record_cash_payment", old, new) do
    empty_cash_movement() |> Map.put(:received_cents, max(new.held - old.held, 0))
  end

  defp classify_cash("transfer_deposit", old, new) do
    delta = new.held - old.held

    empty_cash_movement()
    |> Map.put(:transferred_in_cents, max(delta, 0))
    |> Map.put(:transferred_out_cents, max(-delta, 0))
  end

  defp classify_cash(type, old, new) when type in ["cancel_group", "cancel_rooms"] do
    empty_cash_movement()
    |> Map.put(:refunded_cents, new.refunded - old.refunded)
    |> Map.put(:retained_cents, new.retained - old.retained)
    |> Map.put(:converted_to_credit_cents, new.converted - old.converted)
  end

  defp classify_cash("reduce_cash_payment", old, new) do
    empty_cash_movement() |> Map.put(:reduced_cents, max(old.held - new.held, 0))
  end

  defp classify_cash("charge_back_payment", old, new) do
    refunded = new.refunded - old.refunded
    retained = new.retained - old.retained
    converted = new.converted - old.converted

    charged_back =
      max(old.held - new.held, 0) + max(-refunded, 0) + max(-retained, 0) +
        max(-converted, 0)

    empty_cash_movement()
    |> Map.put(:refunded_cents, refunded)
    |> Map.put(:retained_cents, retained)
    |> Map.put(:converted_to_credit_cents, converted)
    |> Map.put(:charged_back_cents, charged_back)
  end

  defp classify_cash(_type, _old, _new), do: empty_cash_movement()

  defp record_credit_movements(
         partner_operation,
         operation,
         result,
         posting_on,
         late_adjustment,
         before,
         current
       ) do
    movement = classify_credit(operation, result, posting_on, before, current)

    if any_nonzero?(movement) do
      attrs =
        movement
        |> Map.merge(%{
          partner_operation_id: partner_operation.id,
          posting_on: posting_on,
          late_adjustment: late_adjustment
        })

      Repo.insert!(CreditMovement.changeset(%CreditMovement{}, attrs))
    end
  end

  defp classify_credit(%{"type" => type} = operation, result, posting_on, before, current)
       when type in ["cancel_group", "cancel_rooms"] do
    refundable = cancellation_refundable?(operation)

    base =
      empty_credit_movement()
      |> Map.put(:issued_cents, result["credit_issued_cents"] || 0)

    base =
      Enum.reduce(current, base, fn {lot_id, lot}, movement ->
        issued_after_expiry =
          if not Map.has_key?(before, lot_id) and Date.compare(lot.expires_on, posting_on) == :lt,
            do: lot.available,
            else: 0

        Map.update!(movement, :expired_cents, &(&1 + issued_after_expiry))
      end)

    Enum.reduce(Map.keys(before), base, fn lot_id, movement ->
      old = before[lot_id]
      new = Map.get(current, lot_id, empty_lot(old.expires_on))
      removed_from_application = max(old.applied - new.applied, 0)

      if refundable do
        absorbed = max(old.clawback - new.clawback, 0)
        restored = max(new.available - old.available, 0)

        reportable_restoration =
          if Date.compare(old.expires_on, posting_on) == :lt, do: 0, else: restored

        expired = max(removed_from_application - absorbed - reportable_restoration, 0)

        movement
        |> Map.update!(:absorbed_cents, &(&1 + absorbed))
        |> Map.update!(:expired_cents, &(&1 + expired))
      else
        Map.update!(movement, :consumed_cents, &(&1 + removed_from_application))
      end
    end)
  end

  defp classify_credit(%{"type" => "charge_back_payment"}, _result, posting_on, before, current) do
    revoked =
      Enum.sum(
        Enum.map(before, fn {lot_id, old} ->
          new = Map.get(current, lot_id, empty_lot(old.expires_on))

          if Date.compare(old.expires_on, posting_on) in [:eq, :gt],
            do: max(old.available - new.available, 0),
            else: 0
        end)
      )

    empty_credit_movement() |> Map.put(:revoked_cents, revoked)
  end

  defp classify_credit(%{"type" => "apply_hotel_credit"}, _result, posting_on, before, current) do
    reversed_expiry =
      Enum.sum(
        Enum.map(before, fn {lot_id, old} ->
          new = Map.get(current, lot_id, empty_lot(old.expires_on))

          if Date.compare(old.expires_on, posting_on) == :lt do
            min(max(old.available - new.available, 0), max(new.applied - old.applied, 0))
          else
            0
          end
        end)
      )

    empty_credit_movement() |> Map.put(:expired_cents, -reversed_expiry)
  end

  defp classify_credit(_operation, _result, _posting_on, _before, _current),
    do: empty_credit_movement()

  defp cancellation_refundable?(operation) do
    group = Repo.get_by!(Group, group_id: operation["group_id"])
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])

    group.refundable_until != nil and
      Date.compare(occurred_on, group.refundable_until) in [:lt, :eq]
  end

  defp record_credit_lot_events(partner_operation, posting_on, before, current) do
    (Map.keys(before) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn lot_id ->
      expires_on = (Map.get(before, lot_id) || Map.fetch!(current, lot_id)).expires_on
      old = Map.get(before, lot_id, empty_lot(expires_on))
      new = Map.get(current, lot_id, empty_lot(expires_on))
      available_delta = new.available - old.available
      applied_delta = new.applied - old.applied

      if available_delta != 0 or applied_delta != 0 do
        Repo.insert!(
          CreditLotEvent.changeset(%CreditLotEvent{}, %{
            partner_operation_id: partner_operation.id,
            credit_lot_id: lot_id,
            posting_on: posting_on,
            available_delta_cents: available_delta,
            applied_delta_cents: applied_delta
          })
        )
      end
    end)
  end

  defp build_report(setting, date) do
    cash_rows = cash_rows_through(date)
    credit_rows = credit_rows_through(date)

    %{
      date: Date.to_iso8601(date),
      status: report_status(date),
      cash: build_cash_report(date, cash_rows),
      credit: build_credit_report(setting, date, credit_rows),
      late_adjustments: build_late_adjustments(date, cash_rows, credit_rows)
    }
  end

  defp cash_rows_through(date),
    do: Repo.all(from movement in CashMovement, where: movement.posting_on <= ^date)

  defp credit_rows_through(date),
    do: Repo.all(from movement in CreditMovement, where: movement.posting_on <= ^date)

  defp build_cash_report(date, rows) do
    inception =
      Repo.all(
        from balance in CashOpeningBalance,
          select: {balance.property_id, balance.opening_held_cents}
      )
      |> Map.new()

    properties =
      (Map.keys(inception) ++ Enum.map(rows, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(fn property_id ->
      property_rows = Enum.filter(rows, &(&1.property_id == property_id))
      earlier = Enum.filter(property_rows, &(&1.posting_on < date))
      today = Enum.filter(property_rows, &(&1.posting_on == date))
      opening = Map.get(inception, property_id, 0) + Enum.sum(Enum.map(earlier, &cash_effect/1))
      movements = today |> Enum.reject(& &1.late_adjustment) |> sum_cash_movements()
      closing = opening + cash_effect(sum_cash_movements(today))

      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: movements,
        closing_held_cents: closing,
        all_movements: sum_cash_movements(today)
      }
    end)
    |> Enum.reject(fn row ->
      row.opening_held_cents == 0 and row.closing_held_cents == 0 and
        not any_nonzero?(row.all_movements)
    end)
    |> Enum.map(&Map.delete(&1, :all_movements))
  end

  defp build_credit_report(setting, date, rows) do
    automatic = automatic_expiries(setting, date)

    earlier =
      rows
      |> Enum.filter(&(&1.posting_on < date))
      |> sum_credit_movements()
      |> Map.update!(:expired_cents, &(&1 + expiries_before(automatic, date)))

    ordinary_movements =
      rows
      |> Enum.filter(&(&1.posting_on == date and not &1.late_adjustment))
      |> sum_credit_movements()
      |> Map.update!(:expired_cents, &(&1 + Map.get(automatic, date, 0)))

    all_movements =
      rows
      |> Enum.filter(&(&1.posting_on == date))
      |> sum_credit_movements()
      |> Map.update!(:expired_cents, &(&1 + Map.get(automatic, date, 0)))

    opening = setting.opening_credit_liability_cents + credit_effect(earlier)

    %{
      opening_liability_cents: opening,
      movements: ordinary_movements,
      closing_liability_cents: opening + credit_effect(all_movements)
    }
  end

  defp build_late_adjustments(date, cash_rows, credit_rows) do
    cash =
      cash_rows
      |> Enum.filter(&(&1.posting_on == date and &1.late_adjustment))
      |> Enum.group_by(& &1.property_id)
      |> Enum.map(fn {property_id, rows} ->
        %{property_id: property_id, movements: sum_cash_movements(rows)}
      end)
      |> Enum.reject(&(not any_nonzero?(&1.movements)))
      |> Enum.sort_by(& &1.property_id)

    credit =
      credit_rows
      |> Enum.filter(&(&1.posting_on == date and &1.late_adjustment))
      |> sum_credit_movements()

    %{cash: cash, credit: credit}
  end

  defp report_status(date) do
    case latest_close() do
      %PeriodClose{period_end_on: cutoff} ->
        if Date.compare(date, cutoff) in [:lt, :eq], do: "closed", else: "open"

      nil ->
        "open"
    end
  end

  defp later_than_latest_close?(period_end_on) do
    case latest_close() do
      nil -> true
      close -> Date.compare(period_end_on, close.period_end_on) == :gt
    end
  end

  defp automatic_expiries(setting, through_date) do
    openings = Repo.all(CreditOpeningLot)
    events = Repo.all(from event in CreditLotEvent, where: event.posting_on <= ^through_date)

    opening_by_lot = Map.new(openings, &{&1.credit_lot_id, &1.available_cents})
    lot_ids = (Map.keys(opening_by_lot) ++ Enum.map(events, & &1.credit_lot_id)) |> Enum.uniq()

    lots =
      if lot_ids == [],
        do: [],
        else: Repo.all(from lot in CreditLot, where: lot.id in ^lot_ids)

    Enum.reduce(lots, %{}, fn lot, expiries ->
      expiration_day = Date.add(lot.expires_on, 1)

      if Date.compare(expiration_day, setting.starts_on) == :gt and
           Date.compare(expiration_day, through_date) in [:lt, :eq] do
        balance =
          Map.get(opening_by_lot, lot.id, 0) +
            Enum.sum(
              for event <- events,
                  event.credit_lot_id == lot.id,
                  Date.compare(event.posting_on, lot.expires_on) in [:lt, :eq],
                  do: event.available_delta_cents
            )

        Map.update(expiries, expiration_day, max(balance, 0), &(&1 + max(balance, 0)))
      else
        expiries
      end
    end)
  end

  defp expiries_before(expiries, date) do
    expiries
    |> Enum.filter(fn {day, _amount} -> Date.compare(day, date) == :lt end)
    |> Enum.sum_by(&elem(&1, 1))
  end

  defp sum_cash_movements(rows) do
    Enum.reduce(rows, empty_cash_movement(), fn row, totals ->
      Enum.reduce(CashMovement.fields(), totals, fn field, acc ->
        Map.update!(acc, field, &(&1 + Map.fetch!(row, field)))
      end)
    end)
  end

  defp sum_credit_movements(rows) do
    Enum.reduce(rows, empty_credit_movement(), fn row, totals ->
      Enum.reduce(CreditMovement.fields(), totals, fn field, acc ->
        Map.update!(acc, field, &(&1 + Map.fetch!(row, field)))
      end)
    end)
  end

  defp cash_effect(movement) do
    movement.received_cents + movement.transferred_in_cents - movement.transferred_out_cents -
      movement.refunded_cents - movement.retained_cents - movement.converted_to_credit_cents -
      movement.reduced_cents - movement.charged_back_cents
  end

  defp credit_effect(movement) do
    movement.issued_cents - movement.expired_cents - movement.consumed_cents -
      movement.revoked_cents - movement.absorbed_cents
  end

  defp empty_cash_state, do: Map.new(@cash_state_fields, &{&1, 0})
  defp empty_cash_movement, do: Map.new(CashMovement.fields(), &{&1, 0})
  defp empty_credit_movement, do: Map.new(CreditMovement.fields(), &{&1, 0})
  defp empty_lot(expires_on), do: %{available: 0, applied: 0, clawback: 0, expires_on: expires_on}
  defp any_nonzero?(map), do: Enum.any?(map, fn {_key, value} -> value != 0 end)
end
