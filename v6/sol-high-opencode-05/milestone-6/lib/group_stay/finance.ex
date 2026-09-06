defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.{
    Accounting,
    CreditLot,
    FinanceCashMovement,
    FinanceCashOpening,
    FinanceCreditBalanceEvent,
    FinanceCreditMovement,
    FinanceCreditOpening,
    FinanceReporting,
    Group,
    Repo,
    Room,
    RoomFundingAllocation
  }

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  def start(operation_id, starts_on) do
    case Repo.get(FinanceReporting, 1) do
      nil -> create_opening(operation_id, starts_on)
      _reporting -> {:error, "reporting_already_started"}
    end
  end

  def report(date) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        :not_available

      reporting ->
        if Date.before?(date, reporting.starts_on),
          do: :not_available,
          else: {:ok, build_report(reporting, date)}
    end
  end

  def record(operation_id, occurred_on, cash_entries, credit_entries, balance_entries) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        :ok

      reporting ->
        posting_on = later_date(occurred_on, reporting.starts_on)
        insert_cash_movements(operation_id, posting_on, cash_entries)
        insert_credit_movements(operation_id, posting_on, credit_entries)
        insert_balance_events(operation_id, posting_on, occurred_on, balance_entries)
        record_immediate_expiry(operation_id, posting_on, balance_entries)
        :ok
    end
  end

  def revoked_cents(balance_entries, occurred_on) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        0

      _reporting ->
        effective_days = Date.to_gregorian_days(occurred_on)

        Enum.reduce(balance_entries, 0, fn entry, total ->
          if entry.available_delta_cents < 0 do
            lot = Repo.get!(CreditLot, entry.credit_lot_id)

            if effective_days <= lot.expires_on_days,
              do: total - entry.available_delta_cents,
              else: total
          else
            total
          end
        end)
    end
  end

  defp create_opening(operation_id, starts_on) do
    Accounting.ensure_all()

    cash_openings =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_record_id,
          join: group in Group,
          on: group.id == allocation.group_record_id,
          where: allocation.kind == "cash" and room.status == "active",
          group_by: group.property_id,
          select: {group.property_id, sum(allocation.amount_cents)}
      )

    Enum.each(cash_openings, fn {property_id, amount} ->
      Repo.insert!(%FinanceCashOpening{property_id: property_id, amount_cents: amount})
    end)

    applied_by_lot =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_record_id,
          where: allocation.kind == "credit" and room.status == "active",
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    credit_openings =
      Repo.all(CreditLot)
      |> Enum.map(fn lot ->
        available = lot.remaining_cents
        applied = Map.get(applied_by_lot, lot.id, 0)
        {lot, available, applied}
      end)
      |> Enum.reject(fn {_lot, available, applied} -> available == 0 and applied == 0 end)

    Enum.each(credit_openings, fn {lot, available, applied} ->
      Repo.insert!(%FinanceCreditOpening{
        credit_lot_id: lot.id,
        available_cents: available,
        applied_cents: applied,
        expires_on_days: lot.expires_on_days
      })
    end)

    opening_credit =
      Enum.sum(
        Enum.map(credit_openings, fn {_lot, available, applied} -> available + applied end)
      )

    Repo.insert!(%FinanceReporting{
      id: 1,
      start_operation_id: operation_id,
      starts_on: starts_on,
      opening_credit_liability_cents: opening_credit
    })

    :ok
  end

  defp build_report(reporting, date) do
    cash_openings =
      Repo.all(FinanceCashOpening)
      |> Map.new(&{&1.property_id, &1.amount_cents})

    cash_events =
      Repo.all(
        from movement in FinanceCashMovement,
          where: movement.posting_on <= ^date
      )

    properties =
      (Map.keys(cash_openings) ++ Enum.map(cash_events, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        property_events = Enum.filter(cash_events, &(&1.property_id == property_id))
        prior_events = Enum.filter(property_events, &Date.before?(&1.posting_on, date))
        daily_events = Enum.filter(property_events, &(&1.posting_on == date))
        opening = Map.get(cash_openings, property_id, 0) + cash_net(prior_events)
        movements = cash_movement_totals(daily_events)
        closing = opening + cash_net(daily_events)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: movements,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
      end)

    credit_events =
      Repo.all(
        from movement in FinanceCreditMovement,
          where: movement.posting_on <= ^date
      )

    expiries = expiry_movements(reporting.starts_on, date)
    prior_credit = Enum.filter(credit_events, &Date.before?(&1.posting_on, date))
    daily_credit = Enum.filter(credit_events, &(&1.posting_on == date))

    prior_expired =
      expiries
      |> Enum.filter(fn {on, _amount} -> Date.before?(on, date) end)
      |> sum_expiries()

    daily_expired = expiries |> Enum.filter(fn {on, _amount} -> on == date end) |> sum_expiries()

    opening_credit =
      reporting.opening_credit_liability_cents + credit_net(prior_credit, prior_expired)

    credit_movements = credit_movement_totals(daily_credit, daily_expired)
    closing_credit = opening_credit + credit_net(daily_credit, daily_expired)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening_credit,
        movements: credit_movements,
        closing_liability_cents: closing_credit
      }
    }
  end

  defp insert_cash_movements(operation_id, posting_on, entries) do
    entries
    |> aggregate_entries(
      fn {property_id, kind, _amount} -> {property_id, kind} end,
      fn {_property_id, _kind, amount} -> amount end
    )
    |> Enum.each(fn {{property_id, kind}, amount} ->
      if kind in @cash_kinds and amount != 0 do
        Repo.insert!(%FinanceCashMovement{
          operation_id: operation_id,
          posting_on: posting_on,
          property_id: property_id,
          kind: kind,
          amount_cents: amount
        })
      end
    end)
  end

  defp insert_credit_movements(operation_id, posting_on, entries) do
    entries
    |> aggregate_entries(fn {kind, _amount} -> kind end, fn {_kind, amount} -> amount end)
    |> Enum.each(fn {kind, amount} ->
      if kind in @credit_kinds and amount != 0 do
        Repo.insert!(%FinanceCreditMovement{
          operation_id: operation_id,
          posting_on: posting_on,
          kind: kind,
          amount_cents: amount
        })
      end
    end)
  end

  defp insert_balance_events(operation_id, posting_on, effective_on, entries) do
    entries
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_entries} ->
      available = Enum.sum(Enum.map(lot_entries, & &1.available_delta_cents))
      applied = Enum.sum(Enum.map(lot_entries, & &1.applied_delta_cents))

      if available != 0 or applied != 0 do
        Repo.insert!(%FinanceCreditBalanceEvent{
          operation_id: operation_id,
          posting_on: posting_on,
          effective_on: effective_on,
          credit_lot_id: lot_id,
          available_delta_cents: available,
          applied_delta_cents: applied
        })
      end
    end)
  end

  defp record_immediate_expiry(operation_id, posting_on, entries) do
    posting_days = Date.to_gregorian_days(posting_on)

    expired =
      Enum.reduce(entries, 0, fn entry, total ->
        if entry.available_delta_cents > 0 and Map.get(entry, :issued, false) do
          lot = Repo.get!(CreditLot, entry.credit_lot_id)

          if posting_days > lot.expires_on_days + 1,
            do: total + entry.available_delta_cents,
            else: total
        else
          total
        end
      end)

    if expired > 0 do
      Repo.insert!(%FinanceCreditMovement{
        operation_id: operation_id,
        posting_on: posting_on,
        kind: "expired",
        amount_cents: expired
      })
    end
  end

  defp expiry_movements(starts_on, through_date) do
    openings = Repo.all(FinanceCreditOpening) |> Map.new(&{&1.credit_lot_id, &1})
    events = Repo.all(FinanceCreditBalanceEvent)

    lot_ids = (Map.keys(openings) ++ Enum.map(events, & &1.credit_lot_id)) |> Enum.uniq()

    lots =
      Repo.all(from lot in CreditLot, where: lot.id in ^lot_ids)
      |> Map.new(&{&1.id, &1})

    events_by_lot = Enum.group_by(events, & &1.credit_lot_id)

    Enum.flat_map(lot_ids, fn lot_id ->
      lot = Map.fetch!(lots, lot_id)
      expires_on = Date.from_gregorian_days(lot.expires_on_days)
      natural_expiry_on = Date.add(expires_on, 1)
      opening = Map.get(openings, lot_id)

      expiry_on =
        if opening && Date.before?(natural_expiry_on, starts_on),
          do: starts_on,
          else: natural_expiry_on

      if not Date.before?(expiry_on, starts_on) and not Date.after?(expiry_on, through_date) do
        initial = if opening, do: opening.available_cents, else: 0

        delta =
          events_by_lot
          |> Map.get(lot_id, [])
          |> Enum.filter(&(not Date.after?(&1.effective_on, expires_on)))
          |> Enum.map(& &1.available_delta_cents)
          |> Enum.sum()

        amount = max(initial + delta, 0)
        if amount > 0, do: [{expiry_on, amount}], else: []
      else
        []
      end
    end)
  end

  defp cash_movement_totals(events) do
    totals = Map.new(@cash_kinds, &{String.to_atom(&1 <> "_cents"), 0})

    Enum.reduce(events, totals, fn event, result ->
      Map.update!(result, String.to_atom(event.kind <> "_cents"), &(&1 + event.amount_cents))
    end)
  end

  defp credit_movement_totals(events, expired) do
    totals = Map.new(@credit_kinds, &{String.to_atom(&1 <> "_cents"), 0})

    events
    |> Enum.reduce(totals, fn event, result ->
      Map.update!(result, String.to_atom(event.kind <> "_cents"), &(&1 + event.amount_cents))
    end)
    |> Map.update!(:expired_cents, &(&1 + expired))
  end

  defp cash_net(events) do
    Enum.reduce(events, 0, fn event, total ->
      if event.kind in ["received", "transferred_in"],
        do: total + event.amount_cents,
        else: total - event.amount_cents
    end)
  end

  defp credit_net(events, expired) do
    Enum.reduce(events, -expired, fn event, total ->
      if event.kind == "issued", do: total + event.amount_cents, else: total - event.amount_cents
    end)
  end

  defp sum_expiries(expiries), do: Enum.sum(Enum.map(expiries, fn {_on, amount} -> amount end))

  defp aggregate_entries(entries, key, amount) do
    Enum.reduce(entries, %{}, fn entry, totals ->
      Map.update(totals, key.(entry), amount.(entry), &(&1 + amount.(entry)))
    end)
  end

  defp later_date(first, second), do: if(Date.before?(first, second), do: second, else: first)
end
