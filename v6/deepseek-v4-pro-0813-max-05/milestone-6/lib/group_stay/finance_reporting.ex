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
      credit_lot_id: opts[:lot_id]
    })
  end

  @doc "Records a signed credit-side finance movement at a posting date."
  def record_credit_movement(operation_id, posting_date, kind, amount_cents, lot_id \\ nil)

  def record_credit_movement(_operation_id, _posting_date, _kind, amount_cents, _lot_id)
      when amount_cents == 0,
      do: :ok

  def record_credit_movement(operation_id, posting_date, kind, amount_cents, lot_id) do
    Repo.insert!(%FinanceJournal{
      operation_id: operation_id,
      posting_date: posting_date,
      kind: kind,
      property_id: nil,
      amount_cents: amount_cents,
      payment_id: nil,
      credit_lot_id: lot_id
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

    {cash_by_day, credit_by_day} = movement_rows(cutoff, reporting.starts_on)
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
      |> MapSet.union(MapSet.new(Map.keys(opening)))

    running_cash = Map.new(candidates, &{&1, Map.get(opening, &1, 0)})

    {cash_entries, credit_object} =
      Date.range(reporting.starts_on, date)
      |> Enum.reduce({nil, running_cash, base_liability}, fn day, {capture, running, spread} ->
        day_cash = Map.get(cash_by_day, day, %{})
        day_credit = Map.get(credit_by_day, day, %{}) |> Map.take(@credit_kinds)
        day_credit = add_expiry(day_credit, Map.get(expiry_events, day, 0))

        closing_cash =
          Map.new(running, fn {property, held} ->
            moves = Map.get(day_cash, property, %{})
            {property, held + cash_delta(moves)}
          end)

        closing_spread = spread + credit_delta(day_credit)

        new_capture =
          if Date.compare(day, date) == :eq do
            {running, day_cash, closing_cash, spread, day_credit, closing_spread}
          else
            capture
          end

        {new_capture, closing_cash, closing_spread}
      end)
      |> then(fn {capture, _running, _spread} ->
        {
          build_cash_entries(capture, candidates),
          build_credit_object(capture)
        }
      end)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_entries,
      "credit" => credit_object
    }
  end

  defp build_cash_entries(capture, candidates) do
    {opening_running, day_cash, closing_cash, _spread, _day_credit, _closing_spread} = capture

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
    {_opening_running, _day_cash, _closing_cash, spread, day_credit, closing_spread} = capture

    %{
      "opening_liability_cents" => spread,
      "movements" =>
        Map.new(@credit_kinds, fn kind -> {kind <> "_cents", Map.get(day_credit, kind, 0)} end),
      "closing_liability_cents" => closing_spread
    }
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
    |> Enum.reduce({%{}, %{}}, fn row, {cash, credit} ->
      # Post-start entries post on the later of their date and starts_on;
      # this also folds any entry committed concurrently with the start
      # operation onto starts_on.
      posting_date =
        if Date.compare(row.posting_date, starts_on) == :lt do
          starts_on
        else
          row.posting_date
        end

      if is_nil(row.property_id) do
        day = Map.get(credit, posting_date, %{})
        kind_total = Map.get(day, row.kind, 0) + row.amount_cents
        {cash, Map.put(credit, posting_date, Map.put(day, row.kind, kind_total))}
      else
        day = Map.get(cash, posting_date, %{})
        property = Map.get(day, row.property_id, %{})
        kind_total = Map.get(property, row.kind, 0) + row.amount_cents

        cash =
          Map.put(
            cash,
            posting_date,
            Map.put(day, row.property_id, Map.put(property, row.kind, kind_total))
          )

        {cash, credit}
      end
    end)
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
