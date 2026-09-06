defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report and its durable inception point.

  `start_reporting!/2` records the first applied `start_finance_reporting`
  operation: the opening position - the held cash of every property and the
  balance of every credit lot - is captured immediately before that operation
  is processed, including every operation already committed, even one whose
  `occurred_on` is on or after `starts_on`. Reporting then runs on a timeline
  that begins on `starts_on`.

  `daily_report/1` rebuilds each day of that timeline from the stored
  snapshot plus the durable operations committed after the start: every
  finance effect an operation reports posts on the later of its `occurred_on`
  and `starts_on`, so later submissions can change an earlier open report,
  and credit that remains unused through its `expires_on` date expires on the
  following date even when no partner operation was submitted that day.
  Reading a report never changes a report or any domain state.
  """

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Reporting
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @zero_cash %{
    received_cents: 0,
    transferred_in_cents: 0,
    transferred_out_cents: 0,
    refunded_cents: 0,
    retained_cents: 0,
    converted_to_credit_cents: 0,
    reduced_cents: 0,
    charged_back_cents: 0
  }

  @zero_credit %{
    issued_cents: 0,
    expired_cents: 0,
    consumed_cents: 0,
    revoked_cents: 0,
    absorbed_cents: 0
  }

  @doc """
  Enables finance reporting as of `starts_on`, capturing the current
  financial state as the opening position on that date. Returns
  `{:error, :reporting_already_started}` once reporting has started. Runs
  inside the caller's transaction.
  """
  @spec start_reporting!(Date.t(), String.t()) ::
          {:ok, Date.t()} | {:error, :reporting_already_started}
  def start_reporting!(starts_on, operation_id) do
    if Repo.exists?(from(r in Reporting)) do
      {:error, :reporting_already_started}
    else
      %Reporting{}
      |> Ecto.Changeset.cast(
        %{
          starts_on: starts_on,
          start_operation_id: operation_id,
          snapshot: Jason.encode!(capture_snapshot())
        },
        [:starts_on, :start_operation_id, :snapshot]
      )
      |> Repo.insert!()

      {:ok, starts_on}
    end
  end

  @doc """
  The finance report for `date`:

      %{date: ..., status: "open", cash: [...], credit: %{...}}

  or `{:error, :report_not_available}` when reporting has not started or the
  date precedes `starts_on`. Reading a report never changes state.
  """
  @spec daily_report(Date.t()) :: {:ok, map()} | {:error, :report_not_available}
  def daily_report(date) do
    case Repo.one(Reporting) do
      nil ->
        {:error, :report_not_available}

      row ->
        if Date.compare(date, row.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(row, date)}
        end
    end
  end

  ## The opening position

  defp capture_snapshot do
    world = Accounting.replay_all()

    %{
      "cash_by_property" => cash_by_property(world),
      "lots" => lot_snapshots(world)
    }
  end

  # The cash currently held on each property's active rooms.
  defp cash_by_property(world) do
    world.groups
    |> Map.values()
    |> Enum.flat_map(fn state ->
      held =
        state.rooms
        |> Enum.filter(& &1.active)
        |> Enum.flat_map(& &1.cash)
        |> Enum.reduce(0, &(&1.amount + &2))

      if held > 0, do: [{state.group.property_id, held}], else: []
    end)
    |> Enum.reduce(%{}, fn {property, amount}, acc ->
      Map.update(acc, property, amount, fn held -> held + amount end)
    end)
  end

  # Every credit lot's balance at the capture moment: its unapplied remaining,
  # the amount currently funding active groups, and any unrecovered clawback.
  defp lot_snapshots(world) do
    applied = applied_credit_by_lot(world)

    Repo.all(Lot)
    |> Enum.filter(fn lot ->
      Map.get(applied, lot.id, 0) > 0 or lot.remaining_cents > 0 or
        lot.clawback_unrecovered_cents > 0
    end)
    |> Enum.map(fn lot ->
      %{
        "id" => lot.id,
        "source_operation_id" => lot.source_operation_id,
        "expires_on" => Date.to_iso8601(lot.expires_on),
        "remaining_cents" => lot.remaining_cents,
        "applied_cents" => Map.get(applied, lot.id, 0),
        "clawback_unrecovered_cents" => lot.clawback_unrecovered_cents
      }
    end)
  end

  defp applied_credit_by_lot(world) do
    world.groups
    |> Map.values()
    |> Enum.filter(&(&1.group.status == "active"))
    |> Enum.flat_map(& &1.rooms)
    |> Enum.flat_map(& &1.credit)
    |> Enum.group_by(& &1.lot_id, & &1.amount)
    |> Map.new(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)
  end

  ## Report assembly

  defp build_report(row, date) do
    starts_on = row.starts_on
    snapshot = Jason.decode!(row.snapshot)

    report = Accounting.replay_all(collect: {starts_on, start_sequence!(row)}).report

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_entries(snapshot["cash_by_property"], report.cash_buckets, date),
      credit: credit_entry(snapshot["lots"], report.credit_events, starts_on, date)
    }
  end

  defp start_sequence!(row) do
    Repo.one!(
      from r in Record,
        where: r.operation_id == ^row.start_operation_id,
        select: r.sequence
    )
  end

  ## Cash

  # One entry per property whose opening balance, closing balance, or any
  # movement is nonzero, ordered by property id:
  #
  #   closing held = opening held + received + transferred in
  #                  - transferred out - refunded - retained
  #                  - converted to credit - reduced - charged back
  defp cash_entries(snapshot_cash, buckets, date) do
    properties =
      (Map.keys(snapshot_cash) ++ Enum.flat_map(Map.values(buckets), &Map.keys/1))
      |> Enum.uniq()
      |> Enum.sort()

    prior_nets =
      buckets
      |> Enum.filter(fn {day, _by_property} -> Date.compare(day, date) == :lt end)
      |> Enum.map(fn {_day, by_property} -> by_property end)

    Enum.flat_map(properties, fn property ->
      opening =
        Map.get(snapshot_cash, property, 0) +
          Enum.sum(Enum.map(prior_nets, &held_net(Map.get(&1, property, @zero_cash))))

      movements = Map.merge(@zero_cash, Map.get(Map.get(buckets, date, %{}), property, %{}))
      closing = opening + held_net(movements)

      if opening == 0 and closing == 0 and movements == @zero_cash do
        []
      else
        [
          %{
            property_id: property,
            opening_held_cents: opening,
            movements: movements,
            closing_held_cents: closing
          }
        ]
      end
    end)
  end

  defp held_net(kinds) do
    kinds.received_cents + kinds.transferred_in_cents - kinds.transferred_out_cents -
      kinds.refunded_cents - kinds.retained_cents - kinds.converted_to_credit_cents -
      kinds.reduced_cents - kinds.charged_back_cents
  end

  ## Credit

  # The company-wide credit entry. The opening liability is the captured
  # balance of every lot: credit funding active groups, plus unapplied credit
  # that had not yet expired as of `starts_on`. The timeline then replays the
  # collected credit events in posting-date order, so
  #
  #   closing liability = opening liability + issued - expired - consumed
  #                       - revoked - absorbed
  #
  # reconciles with the current liability view on every date.
  defp credit_entry(snapshot_lots, credit_events, starts_on, date) do
    snapshot_opening = opening_liability(snapshot_lots, starts_on)
    movements = simulate_credit(snapshot_lots, credit_events, starts_on)

    # Each day's opening liability is the closing liability of the day before:
    # the captured opening position plus every movement posted before `date`.
    opening =
      movements
      |> Enum.filter(fn {day, _kinds} -> Date.compare(day, date) == :lt end)
      |> Enum.reduce(snapshot_opening, &credit_net_sum/2)

    movements_on_date = Map.merge(@zero_credit, Map.get(movements, date, %{}))
    closing = credit_net_sum({date, movements_on_date}, opening)

    %{
      opening_liability_cents: opening,
      movements: movements_on_date,
      closing_liability_cents: closing
    }
  end

  defp credit_net_sum({_day, kinds}, acc) do
    acc + kinds.issued_cents - kinds.expired_cents - kinds.consumed_cents - kinds.revoked_cents -
      kinds.absorbed_cents
  end

  defp opening_liability(snapshot_lots, starts_on) do
    Enum.reduce(snapshot_lots, 0, fn lot, acc ->
      expires_on = Date.from_iso8601!(lot["expires_on"])
      entered? = Date.compare(expires_on, starts_on) == :gt

      acc + lot["applied_cents"] + if(entered?, do: lot["remaining_cents"], else: 0)
    end)
  end

  # Replays the credit timeline, returning the credit movements keyed by
  # posting date. Credit liability leaves through expiry, consumption,
  # revocation, and shortfall absorption, and enters when issued; applying or
  # restoring credit only moves liability between applied and available
  # balances, so it posts no movement. A lot's expiry posts on the day after
  # its `expires_on` date, taking whatever remains unused at that point in
  # the timeline.
  defp simulate_credit(snapshot_lots, credit_events, starts_on) do
    lot_rows = Repo.all(from l in Lot, select: {l.id, l.source_operation_id, l.expires_on})
    expires_by_id = Map.new(lot_rows, fn {id, _source, expires_on} -> {id, expires_on} end)
    id_by_source = Map.new(lot_rows, fn {id, source, _expires_on} -> {source, id} end)

    states =
      Map.new(snapshot_lots, fn lot ->
        {lot["id"],
         %{
           remaining: lot["remaining_cents"],
           applied: lot["applied_cents"],
           clawback: lot["clawback_unrecovered_cents"],
           expires_on: Date.from_iso8601!(lot["expires_on"]),
           issued?: true
         }}
      end)

    # Lots still holding a balance at the start of the timeline expire on the
    # day after their expires_on date; so do lots issued within the timeline.
    expiry_events =
      for lot <- snapshot_lots,
          expires_on = Date.from_iso8601!(lot["expires_on"]),
          Date.compare(expires_on, starts_on) == :gt do
        {Date.add(expires_on, 1), -1, {:expire, lot["id"]}}
      end ++
        for {_posting, _sequence, {:issue, source, _amount}} <- credit_events,
            lot_id = Map.fetch!(id_by_source, source),
            expires_on = Map.fetch!(expires_by_id, lot_id) do
          {Date.add(expires_on, 1), -1, {:expire, lot_id}}
        end

    events =
      (Enum.map(credit_events, fn {posting, sequence, event} ->
         {posting, sequence, resolve_event(event, id_by_source)}
       end) ++ expiry_events)
      # ISO-8601 dates sort chronologically as strings; Date structs would
      # compare field-by-field in term order instead.
      |> Enum.sort_by(fn {day, sequence, _event} -> {Date.to_iso8601(day), sequence} end)

    acc = %{movements: %{}, lots: states, pending: %{}}

    Enum.reduce(events, acc, fn {day, _sequence, event}, acc ->
      apply_credit_event(acc, day, event, expires_by_id)
    end).movements
  end

  defp resolve_event({:issue, source, amount}, id_by_source),
    do: {:issue, Map.fetch!(id_by_source, source), amount}

  defp resolve_event({:revoke, source, entitlement}, id_by_source),
    do: {:revoke, Map.fetch!(id_by_source, source), entitlement}

  defp resolve_event(event, _id_by_source), do: event

  defp apply_credit_event(acc, day, {:issue, lot_id, amount}, expires_by_id) do
    acc = ensure_lot(acc, lot_id, Map.fetch!(expires_by_id, lot_id))
    state = Map.fetch!(acc.lots, lot_id)

    case Map.pop(acc.pending, lot_id) do
      {nil, _pending} ->
        acc
        |> put_lot(lot_id, %{state | issued?: true, remaining: state.remaining + amount})
        |> bump(day, :issued_cents, amount)

      # The lot's expiry date passed before its issue posts in this timeline:
      # whatever it issues expires immediately instead of becoming available.
      {pending_day, pending} ->
        acc = %{acc | pending: pending}

        acc
        |> put_lot(lot_id, %{state | issued?: true})
        |> bump(day, :issued_cents, amount)
        |> bump(pending_day, :expired_cents, amount)
    end
  end

  defp apply_credit_event(acc, _day, {:apply, portions}, expires_by_id) do
    Enum.reduce(portions, acc, fn {lot_id, amount}, acc ->
      acc = ensure_lot(acc, lot_id, Map.fetch!(expires_by_id, lot_id))
      state = Map.fetch!(acc.lots, lot_id)
      drawn = min(state.remaining, amount)

      put_lot(acc, lot_id, %{
        state
        | remaining: state.remaining - drawn,
          applied: state.applied + amount
      })
    end)
  end

  defp apply_credit_event(acc, day, {:settle, portions, mode}, expires_by_id) do
    Enum.reduce(portions, acc, fn {lot_id, amount}, acc ->
      acc = ensure_lot(acc, lot_id, Map.fetch!(expires_by_id, lot_id))
      state = Map.fetch!(acc.lots, lot_id)
      applied = max(state.applied - amount, 0)

      if mode == :consume do
        acc
        |> put_lot(lot_id, %{state | applied: applied})
        |> bump(day, :consumed_cents, amount)
      else
        # A restoration extinguishes unrecovered clawback before making any
        # amount available; an amount whose expiry has already passed reduces
        # the liability instead of becoming available again.
        absorb = min(state.clawback, amount)
        excess = amount - absorb
        expired_already? = Date.compare(state.expires_on, day) != :gt

        {remaining, expired} =
          if expired_already?, do: {state.remaining, excess}, else: {state.remaining + excess, 0}

        acc
        |> put_lot(lot_id, %{
          state
          | applied: applied,
            clawback: state.clawback - absorb,
            remaining: remaining
        })
        |> bump(day, :absorbed_cents, absorb)
        |> bump(day, :expired_cents, expired)
      end
    end)
  end

  defp apply_credit_event(acc, day, {:revoke, lot_id, entitlement}, expires_by_id) do
    acc = ensure_lot(acc, lot_id, Map.fetch!(expires_by_id, lot_id))
    state = Map.fetch!(acc.lots, lot_id)
    removed = min(state.remaining, entitlement)

    acc
    |> put_lot(lot_id, %{
      state
      | remaining: state.remaining - removed,
        clawback: state.clawback + (entitlement - removed)
    })
    |> bump(day, :revoked_cents, removed)
  end

  defp apply_credit_event(acc, day, {:expire, lot_id}, expires_by_id) do
    acc = ensure_lot(acc, lot_id, Map.fetch!(expires_by_id, lot_id))
    state = Map.fetch!(acc.lots, lot_id)

    if state.issued? do
      acc
      |> put_lot(lot_id, %{state | remaining: 0})
      |> bump(day, :expired_cents, state.remaining)
    else
      # The lot has not been issued in this timeline yet (its issue posts on a
      # later date): remember the expiry so its issue expires immediately.
      %{acc | pending: Map.put(acc.pending, lot_id, day)}
    end
  end

  defp ensure_lot(acc, lot_id, expires_on) do
    case Map.fetch(acc.lots, lot_id) do
      {:ok, _state} ->
        acc

      :error ->
        put_lot(acc, lot_id, %{
          remaining: 0,
          applied: 0,
          clawback: 0,
          expires_on: expires_on,
          issued?: false
        })
    end
  end

  defp put_lot(acc, lot_id, state), do: %{acc | lots: Map.put(acc.lots, lot_id, state)}

  defp bump(acc, _day, _kind, 0), do: acc

  defp bump(acc, day, kind, amount) do
    Map.update!(acc, :movements, fn movements ->
      Map.update(movements, day, Map.put(@zero_credit, kind, amount), fn kinds ->
        Map.update!(kinds, kind, &(&1 + amount))
      end)
    end)
  end
end
