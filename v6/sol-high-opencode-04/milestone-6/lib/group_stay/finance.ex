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

  def record(operation_id, occurred_on, events) do
    case Repo.one(from(r in FinanceReporting, limit: 1)) do
      nil ->
        :ok

      reporting ->
        posting_on = later_date(occurred_on, reporting.starts_on)

        events
        |> Enum.reject(&(&1.amount_cents == 0))
        |> Enum.each(fn event ->
          attrs =
            event
            |> normalize_event(posting_on)
            |> Map.put(:operation_id, operation_id)
            |> Map.put(:posting_on, posting_on)

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

      %{
        date: date,
        status: "open",
        cash: cash_report(reporting, date, events),
        credit: credit_report(reporting, date, events)
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

    properties
    |> Enum.map(fn property_id ->
      {before, today} =
        cash_events
        |> Enum.filter(&(&1.property_id == property_id))
        |> Enum.split_with(&(Date.compare(&1.posting_on, date) == :lt))

      opening_held = Map.get(opening, property_id, 0) + cash_delta(before)
      movements = movement_totals(today, @cash_kinds)
      closing_held = opening_held + cash_delta(today)

      %{
        property_id: property_id,
        opening_held_cents: opening_held,
        movements: cash_movement_map(movements),
        closing_held_cents: closing_held
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
    end)
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

    credit_events = Enum.filter(events, &(&1.kind in @credit_kinds))
    synthetic_expiry = synthetic_expiry(opening_lots, events, reporting.starts_on, date)

    direct_before = Enum.filter(credit_events, &(Date.compare(&1.posting_on, date) == :lt))
    direct_today = Enum.filter(credit_events, &(&1.posting_on == date))

    expired_before =
      Enum.reduce(synthetic_expiry, 0, fn {expiry_date, amount}, total ->
        if Date.compare(expiry_date, date) == :lt, do: total + amount, else: total
      end)

    expired_today = Map.get(synthetic_expiry, date, 0)
    day_totals = movement_totals(direct_today, @credit_kinds)
    day_totals = Map.update!(day_totals, "expired", &(&1 + expired_today))

    opening_for_day = opening_liability + credit_delta(direct_before) - expired_before
    closing = opening_for_day + credit_delta(day_totals)

    %{
      opening_liability_cents: opening_for_day,
      movements: credit_movement_map(day_totals),
      closing_liability_cents: closing
    }
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

    Enum.reduce(lots, %{}, fn {lot_id, lot}, expiries ->
      case safe_expiry_date(lot.expires_on) do
        nil ->
          expiries

        expiry_date ->
          lot_events = Map.get(lifecycle_events, lot_id, [])

          available_at_expiry =
            lot_events
            |> Enum.filter(&(Date.compare(&1.posting_on, expiry_date) == :lt))
            |> Enum.reduce(lot.available, &(&2 + available_delta(&1)))
            |> max(0)

          expiries =
            if Date.compare(expiry_date, starts_on) == :gt and
                 Date.compare(expiry_date, through_date) != :gt and available_at_expiry != 0 do
              Map.update(expiries, expiry_date, available_at_expiry, &(&1 + available_at_expiry))
            else
              expiries
            end

          lot_events
          |> Enum.filter(fn event ->
            Date.compare(event.posting_on, expiry_date) != :lt and
              Date.compare(event.posting_on, through_date) != :gt and
              event.kind in ["issued", "applied"]
          end)
          |> Enum.reduce(expiries, fn event, expiries ->
            adjustment =
              if event.kind == "issued", do: event.amount_cents, else: -event.amount_cents

            Map.update(expiries, event.posting_on, adjustment, &(&1 + adjustment))
          end)
      end
    end)
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

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp normalize_event(%{kind: kind, expires_on: expires_on} = event, posting_on)
       when kind in ["restored", "revoked"] do
    if Date.compare(expires_on, posting_on) == :lt do
      Map.put(event, :kind, if(kind == "restored", do: "expired", else: "available_removed"))
    else
      event
    end
  end

  defp normalize_event(event, _posting_on), do: event
end
