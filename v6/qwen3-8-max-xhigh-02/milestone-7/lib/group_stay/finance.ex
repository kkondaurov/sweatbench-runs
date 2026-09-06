defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  A single `start_finance_reporting` operation snapshots the financial state
  immediately before it as the opening position on `starts_on`. Every later
  applied operation posts its finance effects as movements using the latest
  of its `occurred_on`, `starts_on`, and the day after the reporting cutoff
  at commit time as the posting date. A daily report reconstructs one day
  from the opening position and the movements, so equivalent batches and
  sequential submissions produce equivalent reports and reading never
  changes state.

  A `close_finance_period` operation publishes every report through its
  cutoff: each day is built once and stored, later reads return the stored
  data exactly, and later movements can never post into a closed day.
  Movements whose posting date was moved forward by a close are reported as
  late adjustments.
  """

  import Ecto.Query

  alias GroupStay.Finance.{
    ClosedReport,
    Movement,
    OpeningCashPosition,
    PeriodClose,
    ReportingStart
  }

  alias GroupStay.Groups.{CreditLot, Group, Room, RoomAllocation}
  alias GroupStay.Repo

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  # Effect of one unit of each cash classification on held cash.
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  ## Starting reporting

  @doc """
  Enables finance reporting and snapshots the opening position.

  Runs inside the start operation's transaction. Returns the applied result
  or `{:error, "reporting_already_started"}` when reporting already began.
  """
  def start_reporting(op_id, starts_on) do
    case Repo.one(ReportingStart) do
      nil ->
        opening_credit = opening_credit_liability(starts_on)

        start =
          Repo.insert!(%ReportingStart{
            operation_id: op_id,
            starts_on: starts_on,
            opening_credit_liability_cents: opening_credit
          })

        snapshot_opening_cash(start.id)

        {:ok,
         %{
           "operation_id" => op_id,
           "status" => "applied",
           "starts_on" => Date.to_iso8601(starts_on)
         }}

      _existing ->
        {:error, "reporting_already_started"}
    end
  end

  # The opening credit liability is reported as of starts_on: unexpired
  # available credit plus credit currently applied to active groups.
  defp opening_credit_liability(starts_on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^starts_on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from ra in RoomAllocation,
          where: not is_nil(ra.credit_application_id),
          select: coalesce(sum(ra.amount_cents), 0)
      )

    available + applied
  end

  defp snapshot_opening_cash(start_id) do
    positions =
      Repo.all(
        from ra in RoomAllocation,
          join: r in Room,
          on: ra.room_id == r.id,
          join: g in Group,
          on: r.group_id == g.id,
          where: not is_nil(ra.cash_payment_id),
          group_by: g.property_id,
          select: {g.property_id, sum(ra.amount_cents)}
      )

    Enum.each(positions, fn {property_id, held_cents} ->
      Repo.insert!(%OpeningCashPosition{
        reporting_start_id: start_id,
        property_id: property_id,
        held_cents: held_cents
      })
    end)
  end

  ## Closing a period

  @doc """
  Closes the reporting period through `period_end_on`, publishing every
  report from the previous cutoff (or `starts_on`) through that date.

  Runs inside the close operation's transaction. A close applies only when
  reporting has started, the cutoff is on or after `starts_on`, and it is
  strictly later than the latest successful close; anything else is
  `{:error, "invalid_period"}`.
  """
  def close_period(op_id, period_end_on) do
    start = Repo.one(ReportingStart)
    latest = latest_close_cutoff()

    if start != nil and Date.compare(period_end_on, start.starts_on) != :lt and
         (latest == nil or Date.compare(period_end_on, latest) == :gt) do
      publish_period(start, latest, period_end_on)

      Repo.insert!(%PeriodClose{
        operation_id: op_id,
        period_end_on: period_end_on
      })

      {:ok,
       %{
         "operation_id" => op_id,
         "status" => "applied",
         "period_end_on" => Date.to_iso8601(period_end_on)
       }}
    else
      {:error, "invalid_period"}
    end
  end

  # Builds and stores the immutable report for every newly closed day.
  # Days through the previous cutoff were published by the earlier close.
  defp publish_period(start, latest, period_end_on) do
    from = if latest, do: Date.add(latest, 1), else: start.starts_on

    movements =
      Repo.all(
        from m in Movement,
          where: m.posting_date >= ^start.starts_on and m.posting_date <= ^period_end_on
      )

    lots = Map.new(Repo.all(CreditLot), fn lot -> {lot.id, lot} end)
    expirations = natural_expirations(start, period_end_on, lots)
    opening_cash = opening_cash_map(start.id)

    Enum.each(Date.range(from, period_end_on), fn date ->
      data =
        build_report(
          start,
          date,
          "closed",
          Enum.filter(movements, &(Date.compare(&1.posting_date, date) != :gt)),
          lots,
          Enum.filter(expirations, fn {day, _kind, _amount, _late} ->
            Date.compare(day, date) != :gt
          end),
          opening_cash
        )

      Repo.insert!(%ClosedReport{date: date, data: data})
    end)
  end

  # The cutoff of the latest successful close, or nil when no period has
  # been closed.
  defp latest_close_cutoff do
    Repo.one(from c in PeriodClose, select: max(c.period_end_on))
  end

  ## Recording movements

  @doc """
  Records one cash movement for the property where the cash is held or
  settled. A no-op before reporting has started or for a zero amount.
  """
  def record_cash(_occurred_on, _property_id, _kind, 0), do: :ok

  def record_cash(occurred_on, property_id, kind, amount_cents) do
    case posting(occurred_on) do
      nil ->
        :ok

      {date, late} ->
        Repo.insert!(%Movement{
          posting_date: date,
          scope: "cash",
          property_id: property_id,
          kind: kind,
          amount_cents: amount_cents,
          late: late
        })

        :ok
    end
  end

  @doc """
  Records one company-wide credit movement. A no-op before reporting has
  started or for a zero amount.
  """
  def record_credit(occurred_on, kind, amount_cents, lot_id \\ nil)

  def record_credit(_occurred_on, _kind, 0, _lot_id), do: :ok

  def record_credit(occurred_on, kind, amount_cents, lot_id) do
    case posting(occurred_on) do
      nil ->
        :ok

      {date, late} ->
        Repo.insert!(%Movement{
          posting_date: date,
          scope: "credit",
          property_id: nil,
          kind: kind,
          amount_cents: amount_cents,
          lot_id: lot_id,
          late: late
        })

        :ok
    end
  end

  # The reporting posting date is the latest of occurred_on, starts_on, and
  # the day after the latest close cutoff at commit time; without an
  # occurred_on it is the first open day. A movement whose date is moved
  # forward by a close is marked late. Returns nil when reporting has not
  # started.
  defp posting(occurred_on) do
    case Repo.one(ReportingStart) do
      nil ->
        nil

      start ->
        natural = max_posting(occurred_on, start.starts_on)

        case latest_close_cutoff() do
          nil ->
            {natural, false}

          cutoff ->
            first_open = Date.add(cutoff, 1)

            if Date.compare(first_open, natural) == :gt do
              {first_open, true}
            else
              {natural, false}
            end
        end
    end
  end

  defp max_posting(nil, starts_on), do: starts_on

  defp max_posting(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on
  end

  ## Reading one day

  @doc """
  Builds the daily finance report for a date. Returns
  `{:error, :report_not_available}` before reporting has started or for a
  date before `starts_on`. Closed days return their stored report exactly.
  """
  def daily_report(date) do
    case Repo.one(ReportingStart) do
      nil ->
        {:error, :report_not_available}

      start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get_by(ClosedReport, date: date) do
            %ClosedReport{data: data} -> {:ok, data}
            nil -> {:ok, build_live_report(start, date)}
          end
        end
    end
  end

  defp build_live_report(start, date) do
    movements =
      Repo.all(
        from m in Movement,
          where: m.posting_date >= ^start.starts_on and m.posting_date <= ^date
      )

    lots = Map.new(Repo.all(CreditLot), fn lot -> {lot.id, lot} end)

    build_report(
      start,
      date,
      report_status(date),
      movements,
      lots,
      natural_expirations(start, date, lots),
      opening_cash_map(start.id)
    )
  end

  # Days through the latest cutoff are closed; the stored report normally
  # answers them, so this only guards the live build.
  defp report_status(date) do
    case latest_close_cutoff() do
      nil -> "open"
      cutoff -> if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end

  defp build_report(start, date, status, movements, lots, expirations, opening_cash) do
    %{
      "date" => Date.to_iso8601(date),
      "status" => status,
      "cash" => build_cash(date, movements, opening_cash),
      "credit" => build_credit(start, date, movements, lots, expirations),
      "late_adjustments" => build_late_adjustments(date, movements, expirations)
    }
  end

  ### Cash

  defp build_cash(date, movements, opening) do
    cash_movements = Enum.filter(movements, &(&1.scope == "cash"))

    properties =
      (Map.keys(opening) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    by_property = Enum.group_by(cash_movements, & &1.property_id)

    Enum.flat_map(properties, fn property ->
      entry = cash_entry(property, Map.get(opening, property, 0), by_property, date)

      if cash_entry_empty?(entry) do
        []
      else
        [entry]
      end
    end)
  end

  # The movements block reports ordinary movements only; late movements are
  # reported in late_adjustments but still move the opening and closing
  # balances.
  defp cash_entry(property, opening_held, by_property, date) do
    prop_movements = Map.get(by_property, property, [])

    {prior_net, day_normal, day_late} =
      Enum.reduce(prop_movements, {0, %{}, %{}}, fn m, {net, normal, late} ->
        if Date.compare(m.posting_date, date) == :lt do
          {net + m.amount_cents * Map.fetch!(@cash_signs, m.kind), normal, late}
        else
          if m.late do
            {net, normal, Map.update(late, m.kind, m.amount_cents, &(&1 + m.amount_cents))}
          else
            {net, Map.update(normal, m.kind, m.amount_cents, &(&1 + m.amount_cents)), late}
          end
        end
      end)

    opening_held = opening_held + prior_net

    day_net = cash_net(day_normal) + cash_net(day_late)

    %{
      "property_id" => property,
      "opening_held_cents" => opening_held,
      "movements" => kinds_map(@cash_kinds, day_normal),
      "closing_held_cents" => opening_held + day_net
    }
  end

  defp cash_entry_empty?(entry) do
    entry["opening_held_cents"] == 0 and
      entry["closing_held_cents"] == 0 and
      Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
  end

  defp cash_net(by_kind) do
    Enum.reduce(by_kind, 0, fn {kind, amount}, acc ->
      acc + amount * Map.fetch!(@cash_signs, kind)
    end)
  end

  defp opening_cash_map(start_id) do
    Repo.all(from o in OpeningCashPosition, where: o.reporting_start_id == ^start_id)
    |> Map.new(fn o -> {o.property_id, o.held_cents} end)
  end

  ### Credit

  defp build_credit(start, date, movements, lots, expirations) do
    opening = start.opening_credit_liability_cents

    recorded =
      movements
      |> Enum.filter(&(&1.scope == "credit"))
      |> Enum.flat_map(&credit_event(&1, lots))

    events = recorded ++ expirations

    {prior_net, day_normal, day_late} =
      Enum.reduce(events, {0, %{}, %{}}, fn {event_date, kind, amount, late},
                                            {net, normal, late_acc} ->
        if Date.compare(event_date, date) == :lt do
          {net + credit_sign(kind) * amount, normal, late_acc}
        else
          if late do
            {net, normal, Map.update(late_acc, kind, amount, &(&1 + amount))}
          else
            {net, Map.update(normal, kind, amount, &(&1 + amount)), late_acc}
          end
        end
      end)

    opening_liability = opening + prior_net

    day_net = credit_net(day_normal) + credit_net(day_late)

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => kinds_map(@credit_kinds, day_normal),
      "closing_liability_cents" => opening_liability + day_net
    }
  end

  # A revocation reduces liability only while the lot is still unexpired as
  # of the posting date; a later clawback of already-expired credit is folded
  # back into the lot's expiry instead.
  defp credit_event(%Movement{kind: "revoked"} = m, lots) do
    case Map.get(lots, m.lot_id) do
      nil ->
        []

      lot ->
        if Date.compare(lot.expires_on, m.posting_date) == :lt,
          do: [],
          else: [{m.posting_date, "revoked", m.amount_cents, m.late}]
    end
  end

  defp credit_event(%Movement{} = m, _lots),
    do: [{m.posting_date, m.kind, m.amount_cents, m.late}]

  defp credit_sign("issued"), do: 1
  defp credit_sign(_other), do: -1

  defp credit_net(by_kind) do
    Enum.reduce(by_kind, 0, fn {kind, amount}, acc ->
      acc + credit_sign(kind) * amount
    end)
  end

  # Credit unused through its expires_on date expires the following day, even
  # without an operation. The expired amount is the lot's remaining balance at
  # expiry, so clawbacks posted after the expiry are folded back in. Clawbacks
  # moved forward by a close keep their late marking inside the expiry.
  defp natural_expirations(start, date, lots) do
    expiring =
      for {_id, lot} <- lots,
          Date.compare(lot.expires_on, start.starts_on) != :lt,
          Date.compare(lot.expires_on, date) == :lt do
        lot
      end

    if expiring == [] do
      []
    else
      lot_ids = Enum.map(expiring, & &1.id)

      post_expiry_by_lot =
        Repo.all(
          from m in Movement,
            where: m.scope == "credit" and m.kind == "revoked",
            where: m.lot_id in ^lot_ids
        )
        |> Enum.filter(fn m ->
          lot = Map.get(lots, m.lot_id)
          lot != nil and Date.compare(m.posting_date, lot.expires_on) == :gt
        end)
        |> Enum.group_by(& &1.lot_id)
        |> Map.new(fn {lot_id, ms} ->
          {normal, late} = Enum.split_with(ms, &(not &1.late))

          {lot_id,
           {Enum.sum(Enum.map(normal, & &1.amount_cents)),
            Enum.sum(Enum.map(late, & &1.amount_cents))}}
        end)

      expiring
      |> Enum.flat_map(fn lot ->
        {normal_revoked, late_revoked} = Map.get(post_expiry_by_lot, lot.id, {0, 0})
        day = Date.add(lot.expires_on, 1)
        normal_amount = lot.remaining_cents + normal_revoked

        normal_event =
          if normal_amount > 0, do: [{day, "expired", normal_amount, false}], else: []

        late_event = if late_revoked > 0, do: [{day, "expired", late_revoked, true}], else: []

        normal_event ++ late_event
      end)
    end
  end

  ### Late adjustments

  # Late adjustments are the movements whose posting date a close moved
  # forward, reported on the day they posted.
  defp build_late_adjustments(date, movements, expirations) do
    day_late =
      Enum.filter(movements, fn m ->
        m.late and Date.compare(m.posting_date, date) == :eq
      end)

    %{
      "cash" => late_cash_entries(day_late),
      "credit" => late_credit_map(day_late, expirations, date)
    }
  end

  defp late_cash_entries(day_late) do
    day_late
    |> Enum.filter(&(&1.scope == "cash"))
    |> Enum.group_by(& &1.property_id)
    |> Enum.map(fn {property_id, ms} ->
      by_kind =
        Enum.reduce(ms, %{}, fn m, acc ->
          Map.update(acc, m.kind, m.amount_cents, &(&1 + m.amount_cents))
        end)

      {property_id, kinds_map(@cash_kinds, by_kind)}
    end)
    # A zero-net correction stays visible; only all-zero properties drop out.
    |> Enum.filter(fn {_property_id, movements_map} ->
      Enum.any?(Map.values(movements_map), &(&1 != 0))
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {property_id, movements_map} ->
      %{"property_id" => property_id, "movements" => movements_map}
    end)
  end

  # The credit object is always present, even when every amount is zero.
  defp late_credit_map(day_late, expirations, date) do
    by_kind =
      day_late
      |> Enum.filter(&(&1.scope == "credit"))
      |> Enum.reduce(%{}, fn m, acc ->
        Map.update(acc, m.kind, m.amount_cents, &(&1 + m.amount_cents))
      end)

    by_kind =
      Enum.reduce(expirations, by_kind, fn
        {day, "expired", amount, true}, acc ->
          if day == date do
            Map.update(acc, "expired", amount, &(&1 + amount))
          else
            acc
          end

        _other, acc ->
          acc
      end)

    kinds_map(@credit_kinds, by_kind)
  end

  defp kinds_map(kinds, by_kind) do
    Map.new(kinds, fn kind -> {kind <> "_cents", Map.get(by_kind, kind, 0)} end)
  end
end
