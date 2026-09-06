defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Durable finance reporting: the inception point and the daily report.

  Every applied partner operation writes signed finance movements in the
  same transaction as its domain changes and its durable record. An entry's
  `durable_operation_id` is the durable record that produced it:
  entries committed before the start operation's durable record form the
  opening position; entries committed after it are movements posted on the
  later of the entry's date and `starts_on`.

  Credit expiry is not an operation. It is reconstructed per lot from the
  opening remaining balance plus the lot's reported deltas: a lot that
  remains unused through its `expires_on` date expires on the following
  date, even when no partner operation is submitted that day.

  Reading a report never changes domain state or any report.
  """

  alias GroupStay.{
    CreditLot,
    FinanceJournal,
    FinanceLotDelta,
    FinanceOpenCash,
    FinanceOpenCreditLot,
    FinanceReportingState,
    Group,
    LegacyFunding,
    Repo,
    RoomAllocation
  }

  import Ecto.Query

  @cash_kinds ~w(received transferred_in transferred_out refunded retained
                 converted reduced charged_back)

  @cash_report_kinds %{
    "converted" => "converted_to_credit"
  }

  @cash_identity %{
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  @credit_kinds ~w(issued expired consumed revoked absorbed)

  @credit_identity %{
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  @doc "The durable reporting state, or `nil` before reporting has started."
  def state do
    Repo.one(from(s in FinanceReportingState))
  end

  @doc "The reporting start date, or `nil` before reporting has started."
  def starts_on do
    case state() do
      %FinanceReportingState{starts_on: starts_on} -> starts_on
      nil -> nil
    end
  end

  @doc """
  The latest successful close's cutoff date, or `nil` before any close has
  been applied.
  """
  def closed_through_on do
    case state() do
      %FinanceReportingState{closed_through_on: cutoff} -> cutoff
      nil -> nil
    end
  end

  @doc """
  The posting rule for an operation processed now with base date `base`.

  Returns `{posting_date, late?}`. Posting starts as the later of `base` and
  `starts_on`; when a close has applied and that date is at or before the
  latest cutoff, the operation's complete finance effect posts on the day
  after the cutoff and is flagged late. Otherwise the natural date is kept
  and the movement is not late.
  """
  def posting_info(base) do
    p0 =
      case starts_on() do
        nil -> base
        starts_on -> if Date.compare(base, starts_on) == :lt, do: starts_on, else: base
      end

    case closed_through_on() do
      nil ->
        {p0, false}

      cutoff ->
        if Date.compare(p0, cutoff) == :gt do
          {p0, false}
        else
          {Date.add(cutoff, 1), true}
        end
    end
  end

  @doc """
  Advances the latest close cutoff through `period_end_on` when reporting
  has started, `period_end_on` is on or after `starts_on`, and it is
  strictly later than the latest successful close. Returns
  `{:error, :invalid_period}` otherwise.
  """
  def close(period_end_on) do
    case state() do
      nil ->
        {:error, :invalid_period}

      %FinanceReportingState{} = reporting ->
        valid? =
          Date.compare(period_end_on, reporting.starts_on) != :lt and
            (is_nil(reporting.closed_through_on) or
               Date.compare(period_end_on, reporting.closed_through_on) == :gt)

        if valid? do
          {count, _} =
            Repo.update_all(
              from(s in FinanceReportingState,
                where: is_nil(s.closed_through_on) or s.closed_through_on < ^period_end_on
              ),
              set: [closed_through_on: period_end_on]
            )

          if count == 1 do
            {:ok, period_end_on}
          else
            {:error, :invalid_period}
          end
        else
          {:error, :invalid_period}
        end
    end
  end

  @doc "Records a signed cash-side finance movement at a posting date."
  def record_movement(operation_id, posting_date, kind, property_id, amount_cents, opts \\ [])

  def record_movement(_operation_id, _posting_date, _kind, _property_id, amount_cents, _opts)
      when amount_cents == 0,
      do: :ok

  def record_movement(operation_id, posting_date, kind, property_id, amount_cents, opts) do
    Repo.insert!(%FinanceJournal{
      operation_id: operation_id,
      posting_date: posting_date,
      kind: kind,
      property_id: property_id,
      amount_cents: amount_cents,
      payment_id: opts[:payment_id],
      credit_lot_id: opts[:lot_id],
      late: opts[:late] || false
    })
  end

  @doc "Records a signed credit-side finance movement at a posting date."
  def record_credit_movement(
        operation_id,
        posting_date,
        kind,
        amount_cents,
        lot_id \\ nil,
        opts \\ []
      )

  def record_credit_movement(_operation_id, _posting_date, _kind, amount_cents, _lot_id, _opts)
      when amount_cents == 0,
      do: :ok

  def record_credit_movement(operation_id, posting_date, kind, amount_cents, lot_id, opts) do
    Repo.insert!(%FinanceJournal{
      operation_id: operation_id,
      posting_date: posting_date,
      kind: kind,
      property_id: nil,
      amount_cents: amount_cents,
      payment_id: nil,
      credit_lot_id: lot_id,
      late: opts[:late] || false
    })
  end

  @doc "Records a reported change to a credit lot's remaining balance."
  def record_lot_delta(_operation_id, _posting_date, _lot_id, delta_cents)
      when delta_cents == 0,
      do: :ok

  def record_lot_delta(operation_id, posting_date, lot_id, delta_cents) do
    Repo.insert!(%FinanceLotDelta{
      operation_id: operation_id,
      posting_date: posting_date,
      credit_lot_id: lot_id,
      delta_cents: delta_cents
    })
  end

  @doc """
  Backfills the durable record identifier on every journal entry written by
  the operation that just got its durable record. Runs in the same
  transaction as the record insert. Also pins the start operation's durable
  record when it is the operation being committed.
  """
  def backfill(operation_id, durable_id) do
    Repo.update_all(
      from(j in FinanceJournal, where: j.operation_id == ^operation_id),
      set: [durable_operation_id: durable_id]
    )

    Repo.update_all(
      from(d in FinanceLotDelta, where: d.operation_id == ^operation_id),
      set: [durable_operation_id: durable_id]
    )

    Repo.update_all(
      from(s in FinanceReportingState, where: s.start_operation_id == ^operation_id),
      set: [started_after_durable_id: durable_id]
    )

    :ok
  end

  @doc """
  Enables finance reporting for the first time.

  The financial state immediately before this operation is processed - every
  operation already committed, regardless of its dates - becomes the opening
  position on `starts_on`. Returns `{:error, :already_started}` when a
  different start operation already enabled reporting.
  """
  def start(operation_id, starts_on) do
    case state() do
      %FinanceReportingState{} ->
        {:error, :already_started}

      nil ->
        try do
          Enum.each(Repo.all(Group), &LegacyFunding.ensure_forwarded/1)

          opening_cash()
          |> Enum.each(fn {property_id, cents} ->
            Repo.insert!(%FinanceOpenCash{
              property_id: property_id,
              opening_held_cents: cents
            })
          end)

          Repo.all(from(l in CreditLot, where: l.remaining_cents > 0))
          |> Enum.each(fn lot ->
            Repo.insert!(%FinanceOpenCreditLot{
              credit_lot_id: lot.id,
              opening_remaining_cents: lot.remaining_cents
            })
          end)

          Repo.insert!(%FinanceReportingState{
            starts_on: starts_on,
            start_operation_id: operation_id,
            opening_applied_credit_cents: opening_applied_credit()
          })

          {:ok, starts_on}
        rescue
          Ecto.ConstraintError ->
            {:error, :already_started}
        end
    end
  end

  @doc """
  Builds the daily report for `date`, or `:not_available` before reporting
  has started or for a date before `starts_on`.

  The report is a pure read: it never changes any report or domain state.
  """
  def daily_report(date) do
    case state() do
      nil ->
        :not_available

      %FinanceReportingState{} = reporting ->
        report_for(date, reporting)
    end
  end

  ## Report building

  defp report_for(date, reporting) do
    if Date.compare(date, reporting.starts_on) == :lt do
      :not_available
    else
      {:ok, build_report(date, reporting)}
    end
  end

  defp build_report(date, reporting) do
    cutoff = reporting.started_after_durable_id

    {cash_by_day, credit_by_day, late_cash_by_day, late_credit_by_day} =
      movement_rows(cutoff, reporting.starts_on)

    delta_rows = lot_delta_rows(cutoff)
    lot_bases = Repo.all(FinanceOpenCreditLot)

    base_liability = opening_liability(lot_bases, reporting)
    expiry_events = expiry_events(delta_rows, lot_bases, reporting.starts_on)

    opening = opening_map()

    candidates =
      cash_by_day
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> MapSet.new()
      |> MapSet.union(
        late_cash_by_day
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()
      )
      |> MapSet.union(MapSet.new(Map.keys(opening)))

    running_cash = Map.new(candidates, &{&1, Map.get(opening, &1, 0)})

    {cash_entries, credit_object, late_adjustments} =
      Date.range(reporting.starts_on, date)
      |> Enum.reduce({nil, running_cash, base_liability}, fn day, {capture, running, spread} ->
        day_cash = Map.get(cash_by_day, day, %{})
        day_credit = Map.get(credit_by_day, day, %{}) |> Map.take(@credit_kinds)
        day_credit = add_expiry(day_credit, Map.get(expiry_events, day, 0))

        late_cash = Map.get(late_cash_by_day, day, %{})
        late_credit = Map.get(late_credit_by_day, day, %{}) |> Map.take(@credit_kinds)

        closing_cash =
          Map.new(running, fn {property, held} ->
            moves =
              Map.merge(
                Map.get(day_cash, property, %{}),
                Map.get(late_cash, property, %{}),
                fn _kind, ordinary, late -> ordinary + late end
              )

            {property, held + cash_delta(moves)}
          end)

        closing_spread = spread + credit_delta(day_credit) + credit_delta(late_credit)

        new_capture =
          if Date.compare(day, date) == :eq do
            {running, day_cash, closing_cash, spread, day_credit, closing_spread, late_cash,
             late_credit}
          else
            capture
          end

        {new_capture, closing_cash, closing_spread}
      end)
      |> then(fn {capture, _running, _spread} ->
        {
          build_cash_entries(capture, candidates),
          build_credit_object(capture),
          build_late_adjustments(capture)
        }
      end)

    %{
      "date" => Date.to_iso8601(date),
      "status" => status_for(date, reporting),
      "cash" => cash_entries,
      "credit" => credit_object,
      "late_adjustments" => late_adjustments
    }
  end

  defp status_for(date, reporting) do
    case reporting.closed_through_on do
      nil ->
        "open"

      cutoff ->
        if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end

  defp build_cash_entries(capture, candidates) do
    {opening_running, day_cash, closing_cash, _spread, _day_credit, _closing_spread, _late_cash,
     _late_credit} = capture

    candidates
    |> Enum.map(fn property ->
      moves = cash_movements(Map.get(day_cash, property, %{}))

      {
        property,
        Map.get(opening_running, property, 0),
        moves,
        Map.get(closing_cash, property, 0)
      }
    end)
    |> Enum.filter(fn {_property, daily_opening, moves, daily_closing} ->
      daily_opening != 0 or daily_closing != 0 or
        Enum.any?(moves, fn {_kind, amount} -> amount != 0 end)
    end)
    |> Enum.sort_by(fn {property, _, _, _} -> property end)
    |> Enum.map(fn {property, daily_opening, moves, daily_closing} ->
      %{
        "property_id" => property,
        "opening_held_cents" => daily_opening,
        "movements" =>
          Map.new(moves, fn {kind, amount} ->
            {report_cash_key(kind) <> "_cents", amount}
          end),
        "closing_held_cents" => daily_closing
      }
    end)
  end

  defp report_cash_key(kind), do: Map.get(@cash_report_kinds, kind, kind)

  defp build_credit_object(capture) do
    {_opening_running, _day_cash, _closing_cash, spread, day_credit, closing_spread, _late_cash,
     _late_credit} = capture

    %{
      "opening_liability_cents" => spread,
      "movements" =>
        Map.new(@credit_kinds, fn kind -> {kind <> "_cents", Map.get(day_credit, kind, 0)} end),
      "closing_liability_cents" => closing_spread
    }
  end

  # Late adjustments are movements whose posting date a close moved forward
  # to this day. Cash entries are ordered by property_id and omit all-zero
  # properties; the credit object is always present.
  defp build_late_adjustments(capture) do
    {_opening_running, _day_cash, _closing_cash, _spread, _day_credit, _closing_spread, late_cash,
     late_credit} = capture

    %{
      "cash" => build_late_cash(late_cash),
      "credit" =>
        Map.new(@credit_kinds, fn kind ->
          {kind <> "_cents", Map.get(late_credit, kind, 0)}
        end)
    }
  end

  defp build_late_cash(late_cash) do
    late_cash
    |> Enum.filter(fn {_property, moves} ->
      Enum.any?(moves, fn {_kind, amount} -> amount != 0 end)
    end)
    |> Enum.sort_by(fn {property, _moves} -> property end)
    |> Enum.map(fn {property, moves} ->
      %{
        "property_id" => property,
        "movements" =>
          moves
          |> cash_movements()
          |> Map.new(fn {kind, amount} -> {report_cash_key(kind) <> "_cents", amount} end)
      }
    end)
  end

  defp add_expiry(day_credit, 0), do: day_credit

  defp add_expiry(day_credit, amount),
    do: Map.update(day_credit, "expired", amount, &(&1 + amount))

  defp cash_movements(moves) do
    Map.new(@cash_kinds, fn kind -> {kind, Map.get(moves, kind, 0)} end)
  end

  defp cash_delta(moves) do
    Enum.reduce(moves, 0, fn {kind, amount}, sum ->
      sum + Map.get(@cash_identity, kind, 1) * amount
    end)
  end

  defp credit_delta(moves) do
    Enum.reduce(moves, 0, fn {kind, amount}, sum ->
      sum + Map.get(@credit_identity, kind, 1) * amount
    end)
  end

  defp movement_rows(cutoff, starts_on) do
    Repo.all(
      from(j in FinanceJournal,
        where: not is_nil(j.durable_operation_id) and j.durable_operation_id > ^cutoff
      )
    )
    |> Enum.reduce({%{}, %{}, %{}, %{}}, fn row, {cash, credit, late_cash, late_credit} ->
      # Post-start entries post on the later of their date and starts_on;
      # this also folds any entry committed concurrently with the start
      # operation onto starts_on.
      posting_date =
        if Date.compare(row.posting_date, starts_on) == :lt do
          starts_on
        else
          row.posting_date
        end

      if row.late do
        if is_nil(row.property_id) do
          {cash, credit, late_cash,
           add_kind_movement(late_credit, posting_date, row.kind, row.amount_cents)}
        else
          {cash, credit,
           add_property_movement(
             late_cash,
             posting_date,
             row.property_id,
             row.kind,
             row.amount_cents
           ), late_credit}
        end
      else
        if is_nil(row.property_id) do
          {cash, add_kind_movement(credit, posting_date, row.kind, row.amount_cents), late_cash,
           late_credit}
        else
          {add_property_movement(cash, posting_date, row.property_id, row.kind, row.amount_cents),
           credit, late_cash, late_credit}
        end
      end
    end)
  end

  defp add_kind_movement(by_day, posting_date, kind, amount) do
    day = Map.get(by_day, posting_date, %{})
    Map.put(by_day, posting_date, Map.update(day, kind, amount, &(&1 + amount)))
  end

  defp add_property_movement(by_day, posting_date, property_id, kind, amount) do
    day = Map.get(by_day, posting_date, %{})
    property = Map.get(day, property_id, %{})
    property = Map.update(property, kind, amount, &(&1 + amount))
    Map.put(by_day, posting_date, Map.put(day, property_id, property))
  end

  defp lot_delta_rows(cutoff) do
    Repo.all(
      from(d in FinanceLotDelta,
        where: not is_nil(d.durable_operation_id) and d.durable_operation_id > ^cutoff
      )
    )
  end

  defp opening_map do
    Repo.all(FinanceOpenCash)
    |> Map.new(&{&1.property_id, &1.opening_held_cents})
  end

  defp opening_cash do
    Repo.all(
      from(a in RoomAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.kind == "cash" and a.status == "held" and a.amount_cents > 0,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
      )
    )
  end

  defp opening_applied_credit do
    Repo.aggregate(
      from(a in RoomAllocation,
        where: a.kind == "credit" and a.status == "held" and a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  ## Opening credit liability: applied credit plus the remaining balance of
  ## every lot that has not already passed its expiry date.

  defp opening_liability(lot_bases, reporting) do
    lot_ids = Enum.map(lot_bases, & &1.credit_lot_id)

    expiries =
      if lot_ids == [] do
        %{}
      else
        Repo.all(from(l in CreditLot, where: l.id in ^lot_ids))
        |> Map.new(&{&1.id, &1.expires_on})
      end

    bases_in_scope =
      Enum.reduce(lot_bases, 0, fn base, sum ->
        case Map.get(expiries, base.credit_lot_id) do
          nil ->
            sum

          expires_on ->
            if Date.compare(expires_on, reporting.starts_on) == :lt do
              sum
            else
              sum + base.opening_remaining_cents
            end
        end
      end)

    reporting.opening_applied_credit_cents + bases_in_scope
  end

  ## Expiry: for every lot whose expiry date is at or after `starts_on`, the
  ## balance still unused through its `expires_on` expires the following day.

  defp expiry_events(delta_rows, lot_bases, starts_on) do
    bases_by_lot = Map.new(lot_bases, &{&1.credit_lot_id, &1.opening_remaining_cents})

    deltas_by_lot =
      Enum.group_by(delta_rows, & &1.credit_lot_id, fn delta -> delta end)

    expiries =
      Repo.all(CreditLot)
      |> Map.new(&{&1.id, &1.expires_on})

    Map.keys(deltas_by_lot)
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(bases_by_lot)))
    |> Enum.reduce(%{}, fn lot_id, events ->
      expires_on = Map.get(expiries, lot_id)

      if is_nil(expires_on) or Date.compare(expires_on, starts_on) == :lt do
        events
      else
        remaining_at_expiry =
          Map.get(bases_by_lot, lot_id, 0) +
            Enum.reduce(Map.get(deltas_by_lot, lot_id, []), 0, fn delta, sum ->
              if Date.compare(delta.posting_date, expires_on) != :gt do
                sum + delta.delta_cents
              else
                sum
              end
            end)

        remaining_at_expiry = max(remaining_at_expiry, 0)
        expiry_date = Date.add(expires_on, 1)

        if remaining_at_expiry == 0 do
          events
        else
          Map.update(events, expiry_date, remaining_at_expiry, &(&1 + remaining_at_expiry))
        end
      end
    end)
  end
end
