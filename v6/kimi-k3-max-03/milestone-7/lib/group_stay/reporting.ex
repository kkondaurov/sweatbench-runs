defmodule GroupStay.Reporting do
  @moduledoc """
  The daily finance report: a durable reporting inception point and per-day
  movement aggregation for held cash (per property) and hotel-credit
  liability (company-wide).

  The first applied `start_finance_reporting` operation captures the opening
  position at `starts_on`: per-property held cash and the credit liability as
  of that date. Every operation processed afterward inserts finance events
  (within the same transaction) whose posting date is the later of its
  `occurred_on`, the inception `starts_on`, and the day after the latest
  close cutoff. Reports fold the opening position with the committed events;
  credit expiry that happens without any partner operation is derived from
  the lots' schedules at read time, until a close freezes it into a recorded
  event so the closed reports stop moving.
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
  The reporting posting date for an operation processed with this reporting
  state: its `occurred_on`, raised past the inception `starts_on` and past
  the day after the latest close cutoff. The date chosen at commit never
  moves again.
  """
  def posting_date(occurred_on, state) do
    occurred_on
    |> raise_past(state.starts_on)
    |> raise_past(first_open_day(state))
  end

  defp first_open_day(%{closed_through: nil}), do: nil
  defp first_open_day(%{closed_through: closed}), do: Date.add(closed, 1)

  defp raise_past(date, nil), do: date

  defp raise_past(date, boundary) do
    if Date.compare(date, boundary) == :lt, do: boundary, else: date
  end

  @doc """
  Whether a close pushed the operation's posting date forward: true when a
  cutoff exists and `occurred_on` falls on or before it. Marked movements
  report into `late_adjustments` rather than the ordinary day movements.
  """
  def moved_forward?(_occurred_on, %{closed_through: nil}), do: false

  def moved_forward?(occurred_on, %{closed_through: closed}) do
    Date.compare(occurred_on, closed) != :gt
  end

  @doc """
  Stores an applied operation's finance movements once reporting has
  started. Movements post on the `posting_date/2` and carry the
  `moved_forward?/2` marker; blank classifications and zero amounts are
  skipped. Returns the inserted events (none before reporting starts).
  """
  def record_events(occurred_on, events) do
    case state() do
      nil ->
        []

      state ->
        posting = posting_date(occurred_on, state)
        late = moved_forward?(occurred_on, state)

        events
        |> Enum.reject(fn event ->
          is_nil(event.classification) or Map.get(event, :amount_cents, 0) == 0
        end)
        |> Enum.map(fn event ->
          event
          |> Map.put(:posting_date, posting)
          |> Map.put(:late_adjustment, late)
          |> insert()
        end)
    end
  end

  defp insert(attrs) do
    attrs
    |> FinanceEvent.changeset()
    |> Repo.insert!()
  end

  ## Closing a period

  @doc """
  Publishes every report through `period_end_on`. The derived day-by-day
  credit expiry for those days freezes into recorded events (later
  operations can no longer move the published figures), and the cutoff is
  stored on the singleton state. Called from the operation pipeline inside
  the close operation's transaction.
  """
  def close_period(state, period_end_on) do
    freeze_derived_expiry(state.starts_on, period_end_on)

    state
    |> Ecto.Changeset.change(%{closed_through: period_end_on})
    |> Repo.update!()
  end

  # Lots expiring within the closed days leave the read-time derived pool and
  # become recorded "expired" events, frozen at their current effective
  # balance (remaining plus the post-expiry revocations already recorded, the
  # same value the derived pool would report today).
  defp freeze_derived_expiry(starts_on, cutoff) do
    suppressed =
      Repo.all(
        from e in FinanceEvent,
          where: e.classification == "expired" and not is_nil(e.credit_lot_id),
          select: e.credit_lot_id
      )

    add_backs =
      Repo.all(
        from e in FinanceEvent,
          where: e.classification == "revoked" and not is_nil(e.lot_expires_on),
          select: %{
            credit_lot_id: e.credit_lot_id,
            posting_date: e.posting_date,
            lot_expires_on: e.lot_expires_on,
            amount_cents: e.amount_cents
          }
      )
      |> Enum.filter(fn event ->
        Date.compare(event.posting_date, Date.add(event.lot_expires_on, 1)) != :lt
      end)
      |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
      |> Map.new(fn {lot_id, amounts} -> {lot_id, Enum.sum(amounts)} end)

    Repo.all(
      from l in CreditLot,
        where: l.id not in ^suppressed,
        select: %{id: l.id, expires_on: l.expires_on, remaining_cents: l.remaining_cents}
    )
    |> Enum.filter(fn lot ->
      expiry = Date.add(lot.expires_on, 1)
      Date.compare(expiry, starts_on) == :gt and Date.compare(expiry, cutoff) != :gt
    end)
    |> Enum.each(fn lot ->
      %{
        scope: "credit",
        classification: "expired",
        amount_cents: lot.remaining_cents + Map.get(add_backs, lot.id, 0),
        posting_date: Date.add(lot.expires_on, 1),
        credit_lot_id: lot.id,
        lot_expires_on: lot.expires_on,
        late_adjustment: false
      }
      |> insert()
    end)
  end

  ## Daily report

  @doc """
  Builds the daily report for `date` (on or after the inception date) from
  the opening position and every event committed so far. The `status` is
  `"closed"` for reports on or before the latest close cutoff, `"open"`
  otherwise. Movements are separated into the ordinary day values and the
  `late_adjustments` block (movements a close pushed forward); opening and
  closing balances use both. Reading a report never changes state.
  """
  def daily_report(state, date) do
    cash = cash_entries(state, date)
    credit = credit_report(state, date)

    %{
      date: date,
      status: status_of(state, date),
      cash: Enum.map(cash, &main_entry/1),
      credit: %{
        opening_liability_cents: credit.opening_held_cents,
        movements: credit.movements,
        closing_liability_cents: credit.closing_held_cents
      },
      late_adjustments: %{
        cash: late_entries(cash),
        credit: credit.late_movements
      }
    }
  end

  defp status_of(%{closed_through: nil}, _date), do: "open"

  defp status_of(%{closed_through: closed}, date) do
    if Date.compare(date, closed) != :gt, do: "closed", else: "open"
  end

  # The ordinary report row: property, opening, day movements, closing.
  defp main_entry(entry) do
    Map.take(entry, [:property_id, :opening_held_cents, :movements, :closing_held_cents])
  end

  # The late-adjustment rows: one entry per property showing any late
  # movement, ordered by property identifier.
  defp late_entries(entries) do
    entries
    |> Enum.reject(& &1.late_all_zero)
    |> Enum.map(&%{property_id: &1.property_id, movements: &1.late_movements})
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
            posting_date: e.posting_date,
            late_adjustment: e.late_adjustment
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
            lot_expires_on: e.lot_expires_on,
            late_adjustment: e.late_adjustment
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
          amount_cents: lot.remaining_cents + Map.get(add_back, lot.id, 0),
          late_adjustment: false
        }
      end)

    all_movements = movement_events ++ derived_expiry

    fold_balance(
      all_movements,
      state.opening_credit_liability_cents,
      date,
      @liability_sign,
      FinanceEvent.classifications("credit")
    )
  end

  ## shared balance folding

  # Folds events for one balance (a property's held cash, or company-wide
  # liability): an opening balance before `date`, the dated movements split
  # into ordinary values and late adjustments, and the closing balance.
  # Events with posting dates after `date` are ignored.
  defp fold_balance(events, snapshot_total, date, signs, classifications) do
    zeros = Map.new(classifications, &{&1, 0})

    {pre, ordinary, late} =
      Enum.reduce(
        events,
        {zeros, zeros, zeros},
        fn event, {pre, ordinary, late} ->
          ordinary_or_late =
            if Map.get(event, :late_adjustment, false), do: :late, else: :ordinary

          case Date.compare(event.posting_date, date) do
            :eq ->
              case ordinary_or_late do
                :ordinary ->
                  {pre, add_movement(ordinary, event), late}

                :late ->
                  {pre, ordinary, add_movement(late, event)}
              end

            :lt ->
              {add_movement(pre, event), ordinary, late}

            :gt ->
              {pre, ordinary, late}
          end
        end
      )

    opening = snapshot_total + signed_sum(pre, signs)

    ordinary_movements =
      Map.new(classifications, fn classification ->
        {String.to_atom("#{classification}_cents"), ordinary[classification]}
      end)

    late_movements =
      Map.new(classifications, fn classification ->
        {String.to_atom("#{classification}_cents"), late[classification]}
      end)

    closing = opening + signed_sum(ordinary, signs) + signed_sum(late, signs)

    %{
      opening_held_cents: opening,
      movements: ordinary_movements,
      late_movements: late_movements,
      closing_held_cents: closing,
      all_zero:
        opening == 0 and closing == 0 and
          Enum.all?(ordinary_movements, fn {_class, amount} -> amount == 0 end) and
          Enum.all?(late_movements, fn {_class, amount} -> amount == 0 end),
      late_all_zero: Enum.all?(late_movements, fn {_class, amount} -> amount == 0 end)
    }
  end

  defp add_movement(totals, event) do
    Map.put(totals, event.classification, totals[event.classification] + event.amount_cents)
  end

  defp signed_sum(totals, signs) do
    Enum.reduce(totals, 0, fn {classification, amount}, acc ->
      acc + signs[classification] * amount
    end)
  end
end
