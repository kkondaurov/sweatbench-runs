defmodule GroupStay.Reporting do
  @moduledoc """
  The daily finance report: a durable reporting inception point and per-day
  movement aggregation for held cash (per property) and hotel-credit
  liability (company-wide).

  The first applied `start_finance_reporting` operation captures the opening
  position at `starts_on`: per-property held cash and the credit liability as
  of that date. Every operation processed afterward inserts finance events
  (within the same transaction) whose posting date is the later of its
  `occurred_on` and `starts_on`. Reports fold the opening position with the
  committed events; credit expiry that happens without any partner operation
  is derived from the lots' schedules at read time, never mutating state.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.{Group, Room, RoomAllocation}
  alias GroupStay.Repo
  alias GroupStay.Reporting.{FinanceEvent, ReportingState}

  # How one event inside its classification moves the balance: positive when
  # it increases held cash / liability, negative when it decreases them.
  # Reversals carry negative amounts inside their classification, so the
  # classification itself always points the same way.
  @held_sign %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }
  @liability_sign %{
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  ## Reporting inception

  @doc """
  The singleton reporting state, opening balances preloaded, or `nil` before
  reporting has started.
  """
  def state do
    case Repo.one(ReportingState) do
      nil -> nil
      state -> Repo.preload(state, :opening_balances)
    end
  end

  @doc """
  Turns reporting on at `starts_on`, capturing the opening position: held
  cash per property and the credit liability as of `starts_on`. Called from
  the operation pipeline inside the start operation's transaction.
  """
  def start_reporting(starts_on) do
    %{
      starts_on: starts_on,
      opening_credit_liability_cents: Credit.liability_cents(starts_on),
      opening_balances:
        Enum.map(opening_cash_balances(), fn {property_id, held} ->
          %{property_id: property_id, opening_held_cents: held}
        end)
    }
    |> ReportingState.changeset()
    |> Repo.insert!()
  end

  # One opening row per property actually holding cash, so properties funded
  # by credit alone stay absent from the cash report.
  defp opening_cash_balances do
    Repo.all(
      from a in RoomAllocation,
        join: r in Room,
        on: a.room_id == r.id,
        join: g in Group,
        on: r.group_id == g.id,
        where: a.kind == "cash" and a.disposition == "held",
        group_by: g.property_id,
        having: sum(a.amount_cents) > 0,
        select: {g.property_id, sum(a.amount_cents)}
    )
  end

  ## Event recording

  @doc """
  Stores an applied operation's finance movements once reporting has
  started. Movements post on the later of `occurred_on` and the inception
  `starts_on`; blank classifications and zero amounts are skipped. Returns
  the inserted events (none before reporting starts).
  """
  def record_events(occurred_on, events) do
    case state() do
      nil ->
        []

      %{starts_on: starts_on} ->
        posting_date =
          if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

        events
        |> Enum.reject(fn event ->
          is_nil(event.classification) or Map.get(event, :amount_cents, 0) == 0
        end)
        |> Enum.map(fn event -> insert(Map.put(event, :posting_date, posting_date)) end)
    end
  end

  defp insert(attrs) do
    attrs
    |> FinanceEvent.changeset()
    |> Repo.insert!()
  end

  ## Daily report

  @doc """
  Builds the daily report for `date` (on or after the inception date) from
  the opening position and every event committed so far. Reading a report
  never changes state.
  """
  def daily_report(state, date) do
    %{
      date: date,
      status: "open",
      cash: cash_entries(state, date),
      credit: credit_report(state, date)
    }
  end

  ## cash entries per property

  defp cash_entries(state, date) do
    events =
      Repo.all(
        from e in FinanceEvent,
          where: e.scope == "cash" and e.posting_date <= ^date,
          select: %{
            property_id: e.property_id,
            classification: e.classification,
            amount_cents: e.amount_cents,
            posting_date: e.posting_date
          }
      )

    group_events = Enum.group_by(events, & &1.property_id)
    openings = Map.new(state.opening_balances, &{&1.property_id, &1.opening_held_cents})

    properties = Enum.uniq(Enum.sort(Map.keys(group_events) ++ Map.keys(openings)))

    properties
    |> Enum.map(fn property_id ->
      property_id
      |> property_entry(
        Map.get(group_events, property_id, []),
        Map.get(openings, property_id, 0),
        date
      )
    end)
    |> Enum.reject(& &1.all_zero)
    |> Enum.map(&Map.delete(&1, :all_zero))
  end

  defp property_entry(property_id, events, snapshot, date) do
    fold_balance(events, snapshot, date, @held_sign, FinanceEvent.classifications("cash"))
    |> Map.put(:property_id, property_id)
  end

  ## credit report, company wide

  defp credit_report(%{starts_on: starts_on} = state, date) do
    # All credit events are loaded: post-expiry revocations feed the
    # derived-expiry add-back regardless of the report date (a late-closing
    # report must still see them reversed out of today's remaining balances,
    # and an early report may show a future revocation's add-back without
    # ever double-counting it as a revoked movement).
    events =
      Repo.all(
        from e in FinanceEvent,
          where: e.scope == "credit",
          select: %{
            classification: e.classification,
            amount_cents: e.amount_cents,
            posting_date: e.posting_date,
            credit_lot_id: e.credit_lot_id,
            lot_expires_on: e.lot_expires_on
          }
      )

    {movement_events, revocations} =
      Enum.split_with(events, &(&1.classification != "revoked"))

    {counted_revocations, post_expiry_revocations} =
      Enum.split_with(revocations, fn event ->
        is_nil(event.lot_expires_on) or
          Date.compare(event.posting_date, Date.add(event.lot_expires_on, 1)) == :lt
      end)

    movement_events =
      Enum.filter(movement_events ++ counted_revocations, fn event ->
        Date.compare(event.posting_date, date) != :gt
      end)

    # Lots running through the day-by-day expiry pool exclude those given a
    # recorded immediate-expiry event of their own, and any lot whose expiry
    # date precedes the inception (it never entered the opening liability).
    suppressed =
      events
      |> Enum.filter(&(&1.classification == "expired" and not is_nil(&1.credit_lot_id)))
      |> MapSet.new(& &1.credit_lot_id)

    add_back =
      Enum.group_by(post_expiry_revocations, & &1.credit_lot_id, & &1.amount_cents)
      |> Map.new(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)

    derived_expiry =
      Repo.all(
        from l in CreditLot,
          where: l.id not in ^MapSet.to_list(suppressed),
          select: %{id: l.id, expires_on: l.expires_on, remaining_cents: l.remaining_cents}
      )
      |> Enum.filter(fn lot -> Date.compare(Date.add(lot.expires_on, 1), starts_on) == :gt end)
      |> Enum.filter(fn lot -> Date.compare(Date.add(lot.expires_on, 1), date) != :gt end)
      |> Enum.map(fn lot ->
        %{
          classification: "expired",
          posting_date: Date.add(lot.expires_on, 1),
          amount_cents: lot.remaining_cents + Map.get(add_back, lot.id, 0)
        }
      end)

    all_movements = movement_events ++ derived_expiry

    entry =
      fold_balance(
        all_movements,
        state.opening_credit_liability_cents,
        date,
        @liability_sign,
        FinanceEvent.classifications("credit")
      )

    %{
      opening_liability_cents: entry.opening_held_cents,
      movements: entry.movements,
      closing_liability_cents: entry.closing_held_cents
    }
  end

  ## shared balance folding

  # Folds events for one balance (a property's held cash, or company-wide
  # liability): an opening balance before `date`, the dated movements, and
  # the closing balance. Events with posting dates after `date` are ignored.
  defp fold_balance(events, snapshot_total, date, signs, classifications) do
    {pre, day} =
      Enum.reduce(
        events,
        {Map.new(classifications, &{&1, 0}), Map.new(classifications, &{&1, 0})},
        fn event, {pre, day} ->
          case Date.compare(event.posting_date, date) do
            :eq ->
              {pre,
               Map.put(day, event.classification, day[event.classification] + event.amount_cents)}

            :lt ->
              {Map.put(pre, event.classification, pre[event.classification] + event.amount_cents),
               day}

            :gt ->
              {pre, day}
          end
        end
      )

    opening = snapshot_total + signed_sum(pre, signs)

    day_movements =
      Map.new(classifications, fn classification ->
        {String.to_atom("#{classification}_cents"), day[classification]}
      end)

    closing = opening + signed_sum(day, signs)

    %{
      opening_held_cents: opening,
      movements: day_movements,
      closing_held_cents: closing,
      all_zero:
        opening == 0 and closing == 0 and
          Enum.all?(day_movements, fn {_class, amount} -> amount == 0 end)
    }
  end

  defp signed_sum(totals, signs) do
    Enum.reduce(totals, 0, fn {classification, amount}, acc ->
      acc + signs[classification] * amount
    end)
  end
end
