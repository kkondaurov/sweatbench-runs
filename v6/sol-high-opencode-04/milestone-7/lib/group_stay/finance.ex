defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{
    CreditLot,
    FinanceEvent,
    FinanceOpeningCash,
    FinanceOpeningCredit,
    FinanceReporting,
    Group,
    Repo,
    RoomFundingAllocation
  }

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  def start(starts_on) do
    if Repo.one(from(r in FinanceReporting, limit: 1)) do
      {:error, :already_started}
    else
      reporting =
        %FinanceReporting{}
        |> FinanceReporting.changeset(%{starts_on: starts_on})
        |> Repo.insert!()

      snapshot_cash(reporting)
      snapshot_credit(reporting)
      :ok
    end
  end

  def close(period_end_on) do
    case Repo.one(from(r in FinanceReporting, limit: 1)) do
      nil ->
        {:error, :invalid_period}

      reporting ->
        valid_start? = Date.compare(period_end_on, reporting.starts_on) != :lt

        later_than_close? =
          is_nil(reporting.closed_through) or
            Date.compare(period_end_on, reporting.closed_through) == :gt

        if valid_start? and later_than_close? do
          reporting
          |> FinanceReporting.changeset(%{closed_through: period_end_on})
          |> Repo.update!()

          :ok
        else
          {:error, :invalid_period}
        end
    end
  end

  def record(operation_id, occurred_on, events) do
    case Repo.one(from(r in FinanceReporting, limit: 1)) do
      nil ->
        :ok

      reporting ->
        baseline = later_date(occurred_on, reporting.starts_on)

        posting_on =
          case reporting.closed_through do
            nil -> baseline
            closed_through -> later_date(baseline, Date.add(closed_through, 1))
          end

        late_adjustment = Date.compare(posting_on, baseline) == :gt

        events
        |> Enum.reject(&(&1.amount_cents == 0))
        |> Enum.each(fn event ->
          attrs =
            event
            |> normalize_event(posting_on, late_adjustment)
            |> Map.put(:operation_id, operation_id)
            |> Map.put(:posting_on, posting_on)
            |> Map.put(:late_adjustment, late_adjustment)

          %FinanceEvent{} |> FinanceEvent.changeset(attrs) |> Repo.insert!()
        end)

        :ok
    end
  end

  def daily_report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.one(from(r in FinanceReporting, limit: 1)) do
          nil -> :not_available
          reporting -> build_report(reporting, date)
        end
      end)

    result
  end

  defp build_report(reporting, date) do
    if Date.compare(date, reporting.starts_on) == :lt do
      :not_available
    else
      events =
        Repo.all(
          from(e in FinanceEvent,
            where: e.posting_on <= ^date,
            order_by: [asc: e.posting_on, asc: e.id]
          )
        )

      {cash, late_cash} = cash_report(reporting, date, events)
      {credit, late_credit} = credit_report(reporting, date, events)

      %{
        date: date,
        status: report_status(reporting, date),
        cash: cash,
        credit: credit,
        late_adjustments: %{cash: late_cash, credit: late_credit}
      }
    end
  end

  defp snapshot_cash(reporting) do
    Repo.all(
      from(a in RoomFundingAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.kind == "cash",
        select: {g.property_id, a.amount_cents}
      )
    )
    |> Enum.each(fn {property_id, amount} ->
      %FinanceOpeningCash{}
      |> FinanceOpeningCash.changeset(%{
        finance_reporting_id: reporting.id,
        property_id: property_id,
        held_cents: amount
      })
      |> Repo.insert!()
    end)
  end

  defp snapshot_credit(reporting) do
    applied =
      Repo.all(
        from(a in RoomFundingAllocation,
          where: a.kind == "credit",
          select: {a.credit_lot_id, a.amount_cents}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)

    Repo.all(CreditLot)
    |> Enum.each(fn lot ->
      applied_cents = Map.get(applied, lot.id, 0)

      if lot.remaining_cents != 0 or applied_cents != 0 do
        %FinanceOpeningCredit{}
        |> FinanceOpeningCredit.changeset(%{
          finance_reporting_id: reporting.id,
          credit_lot_id: lot.id,
          available_cents: lot.remaining_cents,
          applied_cents: applied_cents,
          expires_on: lot.expires_on
        })
        |> Repo.insert!()
      end
    end)
  end

  defp cash_report(reporting, date, events) do
    opening =
      Repo.all(
        from(o in FinanceOpeningCash,
          where: o.finance_reporting_id == ^reporting.id,
          select: {o.property_id, o.held_cents}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {property_id, amounts} -> {property_id, Enum.sum(amounts)} end)

    cash_events = Enum.filter(events, &(&1.kind in @cash_kinds))

    properties =
      (Map.keys(opening) ++ Enum.map(cash_events, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(properties, fn property_id ->
        {before, today} =
          cash_events
          |> Enum.filter(&(&1.property_id == property_id))
          |> Enum.split_with(&(Date.compare(&1.posting_on, date) == :lt))

        opening_held = Map.get(opening, property_id, 0) + cash_delta(before)
        {late_today, ordinary_today} = Enum.split_with(today, & &1.late_adjustment)
        ordinary_movements = movement_totals(ordinary_today, @cash_kinds)
        late_movements = movement_totals(late_today, @cash_kinds)
        closing_held = opening_held + cash_delta(today)

        {
          %{
            property_id: property_id,
            opening_held_cents: opening_held,
            movements: cash_movement_map(ordinary_movements),
            closing_held_cents: closing_held
          },
          %{property_id: property_id, movements: cash_movement_map(late_movements)}
        }
      end)

    cash =
      entries
      |> Enum.reject(fn {entry, late} ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          zero_movements?(entry.movements) and zero_movements?(late.movements)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash =
      entries
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&zero_movements?(&1.movements))

    {cash, late_cash}
  end

  defp credit_report(reporting, date, events) do
    opening_lots =
      Repo.all(
        from(o in FinanceOpeningCredit,
          where: o.finance_reporting_id == ^reporting.id
        )
      )

    opening_liability =
      Enum.reduce(opening_lots, 0, fn lot, total ->
        available =
          if Date.compare(lot.expires_on, reporting.starts_on) == :lt,
            do: 0,
            else: lot.available_cents

        total + available + lot.applied_cents
      end)

    credit_events =
      Enum.filter(events, &(&1.kind in @credit_kinds)) ++
        synthetic_expiry(opening_lots, events, reporting.starts_on, date)

    {before, today} =
      Enum.split_with(credit_events, &(Date.compare(&1.posting_on, date) == :lt))

    {late_today, ordinary_today} = Enum.split_with(today, & &1.late_adjustment)
    ordinary_movements = movement_totals(ordinary_today, @credit_kinds)
    late_movements = movement_totals(late_today, @credit_kinds)
    opening_for_day = opening_liability + credit_delta(before)
    closing = opening_for_day + credit_delta(today)

    {%{
       opening_liability_cents: opening_for_day,
       movements: credit_movement_map(ordinary_movements),
       closing_liability_cents: closing
     }, credit_movement_map(late_movements)}
  end

  defp synthetic_expiry(opening_lots, events, starts_on, through_date) do
    lots =
      Map.new(opening_lots, fn lot ->
        {lot.credit_lot_id, %{available: lot.available_cents, expires_on: lot.expires_on}}
      end)

    lifecycle_events =
      events
      |> Enum.filter(&(not is_nil(&1.credit_lot_id)))
      |> Enum.group_by(& &1.credit_lot_id)

    lots =
      Enum.reduce(events, lots, fn
        %{kind: "issued"} = event, lots ->
          Map.put_new(lots, event.credit_lot_id, %{available: 0, expires_on: event.expires_on})

        _event, lots ->
          lots
      end)

    Enum.flat_map(lots, fn {lot_id, lot} ->
      case safe_expiry_date(lot.expires_on) do
        nil ->
          []

        expiry_date ->
          lot_events = Map.get(lifecycle_events, lot_id, [])

          available_at_expiry =
            lot_events
            |> Enum.filter(&(Date.compare(&1.posting_on, expiry_date) == :lt))
            |> Enum.reduce(lot.available, &(&2 + available_delta(&1)))
            |> max(0)

          natural_expiry =
            if Date.compare(expiry_date, starts_on) == :gt and
                 Date.compare(expiry_date, through_date) != :gt and available_at_expiry != 0 do
              [expiry_event(expiry_date, available_at_expiry, false)]
            else
              []
            end

          adjustments =
            lot_events
            |> Enum.filter(fn event ->
              Date.compare(event.posting_on, expiry_date) != :lt and
                Date.compare(event.posting_on, through_date) != :gt and
                event.kind in ["issued", "applied", "revoked"]
            end)
            |> Enum.map(fn event ->
              adjustment =
                if event.kind == "issued", do: event.amount_cents, else: -event.amount_cents

              expiry_event(event.posting_on, adjustment, event.late_adjustment)
            end)

          natural_expiry ++ adjustments
      end
    end)
  end

  defp expiry_event(posting_on, amount_cents, late_adjustment) do
    %{
      kind: "expired",
      posting_on: posting_on,
      amount_cents: amount_cents,
      late_adjustment: late_adjustment
    }
  end

  defp available_delta(event) do
    case event.kind do
      kind when kind in ["issued", "restored"] -> event.amount_cents
      kind when kind in ["applied", "revoked", "available_removed"] -> -event.amount_cents
      _ -> 0
    end
  end

  defp safe_expiry_date(nil), do: nil

  defp safe_expiry_date(expires_on) do
    Date.add(expires_on, 1)
  rescue
    ArgumentError -> nil
  end

  defp movement_totals(events, kinds) when is_list(events) do
    totals = Map.new(kinds, &{&1, 0})

    Enum.reduce(events, totals, fn event, totals ->
      Map.update!(totals, event.kind, &(&1 + event.amount_cents))
    end)
  end

  defp cash_delta(events) when is_list(events),
    do: events |> movement_totals(@cash_kinds) |> cash_delta()

  defp cash_delta(totals) do
    totals["received"] + totals["transferred_in"] - totals["transferred_out"] -
      totals["refunded"] - totals["retained"] - totals["converted_to_credit"] -
      totals["reduced"] - totals["charged_back"]
  end

  defp credit_delta(events) when is_list(events),
    do: events |> movement_totals(@credit_kinds) |> credit_delta()

  defp credit_delta(totals) do
    totals["issued"] - totals["expired"] - totals["consumed"] - totals["revoked"] -
      totals["absorbed"]
  end

  defp cash_movement_map(totals) do
    %{
      received_cents: totals["received"],
      transferred_in_cents: totals["transferred_in"],
      transferred_out_cents: totals["transferred_out"],
      refunded_cents: totals["refunded"],
      retained_cents: totals["retained"],
      converted_to_credit_cents: totals["converted_to_credit"],
      reduced_cents: totals["reduced"],
      charged_back_cents: totals["charged_back"]
    }
  end

  defp credit_movement_map(totals) do
    %{
      issued_cents: totals["issued"],
      expired_cents: totals["expired"],
      consumed_cents: totals["consumed"],
      revoked_cents: totals["revoked"],
      absorbed_cents: totals["absorbed"]
    }
  end

  defp zero_movements?(movements), do: Enum.all?(movements, fn {_kind, amount} -> amount == 0 end)

  defp report_status(%{closed_through: nil}, _date), do: "open"

  defp report_status(reporting, date) do
    if Date.compare(date, reporting.closed_through) == :gt, do: "open", else: "closed"
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp normalize_event(%{kind: "revoked"} = event, _posting_on, true), do: event

  defp normalize_event(
         %{kind: kind, expires_on: expires_on} = event,
         posting_on,
         _late_adjustment
       )
       when kind in ["restored", "revoked"] do
    if Date.compare(expires_on, posting_on) == :lt do
      Map.put(event, :kind, if(kind == "restored", do: "expired", else: "available_removed"))
    else
      event
    end
  end

  defp normalize_event(event, _posting_on, _late_adjustment), do: event
end
