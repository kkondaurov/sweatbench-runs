defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting over held cash and hotel-credit liability.

  Reporting starts once with a `start_finance_reporting` partner operation.
  The financial state immediately before that operation is processed becomes
  the opening position on `starts_on`; operations processed afterwards record
  movements whose posting date is the later of their `occurred_on` and
  `starts_on`. Inside one batch, operations before the start feed the opening
  position and operations after it post movements.

  A `close_finance_period` operation publishes every report through its
  cutoff: those days' reports are frozen as stored snapshots and never change
  again, whatever later operations or later closes do. An operation processed
  after a close posts on the later of its `occurred_on`, the reporting start
  date, and the first open day after the latest cutoff; when the close moved
  the posting date forward, the movement is a late adjustment and surfaces in
  the report's `late_adjustments` block in addition to the balances it feeds.

  Cash movements are signed net amounts per property in their named
  classification (a chargeback reverses an earlier refund with negative
  refunded and positive charged-back rows). Credit movements are positive
  magnitudes per lot; liability enters through issuance and leaves through
  expiry, consumption, revocation, and shortfall absorption. Applying or
  restoring credit never moves liability. A lot's unused remainder expires on
  the date after its `expires_on`; that movement has no partner operation, so
  it is derived at read time from each lot's current remainder plus the
  dormant revocations and restore-expiries that happened after the boundary.
  Reading a report never changes a report or any domain state.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.OpeningCash
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.ReportingState
  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  # Cash classifications that change held cash, and the sign with which each
  # stored amount moves it. Stored amounts are themselves signed (a
  # chargeback records a negative refund), so the sign is a direction only.
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  # Credit classifications that change liability. Dormant revocations (an
  # entitlement revoked after its lot expired) move no liability and are
  # excluded; they only feed the boundary derivation.
  @credit_signs %{
    "issued" => 1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1,
    "expired_restore" => -1
  }

  # Cash movement keys in report order.
  @cash_movement_keys [
    {"received", "received_cents"},
    {"transferred_in", "transferred_in_cents"},
    {"transferred_out", "transferred_out_cents"},
    {"refunded", "refunded_cents"},
    {"retained", "retained_cents"},
    {"converted", "converted_to_credit_cents"},
    {"reduced", "reduced_cents"},
    {"charged_back", "charged_back_cents"}
  ]

  # Credit movement keys in report order; the day's expiry combines the
  # recorded restore-expiries with lots crossing their expiry boundary.
  @credit_movement_keys [
    {"issued", "issued_cents"},
    {"expired", "expired_cents"},
    {"consumed", "consumed_cents"},
    {"revoked", "revoked_cents"},
    {"absorbed", "absorbed_cents"}
  ]

  @doc """
  Whether finance reporting has started.
  """
  def started? do
    Repo.exists?(ReportingState)
  end

  @doc """
  The reporting start date, or `nil` before reporting started.
  """
  def starts_on do
    Repo.one(from r in ReportingState, select: r.starts_on)
  end

  @doc """
  Turns reporting on with the given start date, snapshotting the opening
  position: held cash per property and the company-wide credit liability as
  of `starts_on`. Both describe the state immediately before this operation
  is processed, including operations already committed in the same batch.
  Returns `:already_started` when reporting is already on; the caller
  guarantees the date is valid.
  """
  def start(%Date{} = starts_on, operation_id) do
    if started?() do
      :already_started
    else
      opening_cash = held_by_property()
      opening_liability = Credits.liability_cents(starts_on)

      %{
        singleton: "current",
        operation_id: operation_id,
        starts_on: starts_on,
        opening_liability_cents: opening_liability
      }
      |> ReportingState.changeset()
      |> Repo.insert!()

      Enum.each(opening_cash, fn {property_id, held} ->
        if held != 0 do
          %OpeningCash{}
          |> change(property_id: property_id, opening_held_cents: held)
          |> Repo.insert!()
        end
      end)

      :ok
    end
  end

  # Held cash summed per property.
  defp held_by_property do
    from(a in CashAllocation,
      join: g in Group,
      on: a.group_id == g.id,
      where: a.status == "held",
      group_by: g.property_id,
      select: {g.property_id, sum(a.amount_cents)}
    )
    |> Repo.all()
  end

  @doc """
  The reporting posting date of an operation processed now: the later of its
  `occurred_on`, the reporting start date, and the first open day after the
  latest close. Returns `nil` before reporting started (when operations only
  feed a future opening position). Only safe after the operation passed
  common validation.
  """
  def posting_date(op) do
    op |> posting_info() |> elem(0)
  end

  @doc """
  The posting date of an operation processed now paired with whether a close
  moved that date forward (making every movement it records a late
  adjustment). An operation keeps the posting date chosen when it commits;
  a later close never moves it again.
  """
  def posting_info(op) do
    {:ok, occurred} = Date.from_iso8601(op["occurred_on"])

    case starts_on() do
      nil ->
        {nil, false}

      %Date{} = starts_on ->
        natural = later(occurred, starts_on)

        case closed_through() do
          %Date{} = cutoff ->
            if Date.compare(natural, cutoff) == :gt do
              {natural, false}
            else
              {Date.add(cutoff, 1), true}
            end

          nil ->
            {natural, false}
        end
    end
  end

  defp later(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end

  @doc """
  The latest successful close, or `nil` before any close.
  """
  def latest_close do
    Repo.one(from c in PeriodClose, order_by: [desc: c.period_end_on], limit: 1)
  end

  @doc """
  The cutoff through which reports are published, or `nil` before any close.
  """
  def closed_through do
    Repo.one(
      from c in PeriodClose,
        order_by: [desc: c.period_end_on],
        limit: 1,
        select: c.period_end_on
    )
  end

  @doc """
  Closes the finance period through `period_end_on`: every daily report from
  the day after the previous cutoff (or the reporting start date) through the
  new cutoff is frozen as a stored snapshot and stays byte-for-byte stable
  across later operations, later closes, and restarts. Returns an error tag
  when reporting has not started, the cutoff is before the start date, or it
  does not move strictly past the latest successful close. Runs inside the
  caller's transaction together with the closing operation's durable record.
  """
  def close_period(%Date{} = period_end_on, operation_id) do
    case Repo.one(ReportingState) do
      nil ->
        {:invalid_period}

      %ReportingState{} = state ->
        latest = latest_close()

        if invalid_cutoff?(period_end_on, state, latest) do
          {:invalid_period}
        else
          %{
            period_end_on: period_end_on,
            operation_id: operation_id
          }
          |> PeriodClose.changeset()
          |> Repo.insert!()

          first_open =
            case latest do
              nil -> state.starts_on
              %PeriodClose{} = close -> Date.add(close.period_end_on, 1)
            end

          first_open
          |> Date.range(period_end_on)
          |> Enum.each(fn date ->
            %{date: date, data: Jason.encode!(report(date, state, "closed"))}
            |> ClosedReport.changeset()
            |> Repo.insert!()
          end)

          :ok
        end
    end
  end

  defp invalid_cutoff?(period_end_on, state, latest) do
    Date.compare(period_end_on, state.starts_on) == :lt or
      (latest != nil and Date.compare(period_end_on, latest.period_end_on) != :gt)
  end

  @doc """
  Records finance movements for one applied operation inside its transaction.
  Each entry is a map with `posting_date`, `kind`, `amount_cents`, whether a
  close moved the posting date forward (`late_adjustment`), and optionally
  `property_id`, `credit_lot_id`, and `operation_id`. Entries without a
  posting date (reporting not started) or with a zero amount leave no
  movement.
  """
  def record(movements) when is_list(movements) do
    movements
    |> Enum.filter(fn movement ->
      movement[:posting_date] != nil and movement[:amount_cents] != 0
    end)
    |> Enum.each(fn movement ->
      %Movement{}
      |> change(
        posting_date: movement[:posting_date],
        kind: movement[:kind],
        amount_cents: movement[:amount_cents],
        operation_id: movement[:operation_id],
        property_id: movement[:property_id],
        credit_lot_id: movement[:credit_lot_id],
        late_adjustment: movement[:late_adjustment] || false
      )
      |> Repo.insert!()
    end)

    :ok
  end

  @doc """
  The daily report for the given date, or `nil` when reporting has not
  started or the date precedes the start. A report contains the date, its
  status, the per-property cash rows ordered by property (a property with
  zero opening, closing, and every movement is omitted), the company-wide
  credit position, and the late adjustments moved forward into the day by a
  close. A published day returns its frozen snapshot; a later day is computed
  live and marked open. Reading a report never changes state.
  """
  def daily_report(%Date{} = date) do
    case Repo.one(ReportingState) do
      nil ->
        nil

      %ReportingState{} = state ->
        if Date.compare(date, state.starts_on) == :lt do
          nil
        else
          case Repo.get_by(ClosedReport, date: date) do
            %ClosedReport{data: data} -> Jason.decode!(data)
            nil -> report(date, state, "open")
          end
        end
    end
  end

  # The live report for one day: cash rows and the credit position carry the
  # day's ordinary movements plus its opening and closing balances, which
  # also absorb the day's late adjustments; the adjustments themselves are
  # listed separately.
  defp report(date, state, status) do
    movements = Repo.all(from m in Movement, order_by: [asc: m.id])
    boundaries = boundary_expiries(movements, state.starts_on)

    {cash, late_cash} = cash_rows(date, movements)
    {credit, late_credit} = credit_position(date, state, movements, boundaries)

    %{
      "date" => Date.to_string(date),
      "status" => status,
      "cash" => cash,
      "credit" => credit,
      "late_adjustments" => %{
        "cash" => late_cash,
        "credit" => late_credit
      }
    }
  end

  ## credit position

  # The credit object and the day's late credit adjustments: opening
  # liability, the day's movements, and closing liability use every recorded
  # movement, while the ordinary movement columns and the late block each
  # carry only their own share. The day's ordinary expiry combines recorded
  # restore-expiries with the derived expiry of lots crossing their boundary
  # on this date; the derived expiry has no partner operation and is never a
  # late adjustment.
  defp credit_position(date, state, movements, boundaries) do
    credit = Enum.filter(movements, &Map.has_key?(@credit_signs, &1.kind))
    on_date = Enum.filter(credit, &same_day?(&1.posting_date, date))
    {ordinary, late} = Enum.split_with(on_date, &(not &1.late_adjustment))

    derived_on = Map.get(boundaries, date, 0)

    opening =
      state.opening_liability_cents + signed_credit(credit, :before, date) -
        derived_before(boundaries, date)

    closing = opening + signed_credit(on_date) - derived_on

    movements_map =
      Map.new(@credit_movement_keys, fn {kind, key} ->
        amount =
          if kind == "expired" do
            sum_by_kind(ordinary, "expired_restore") + derived_on
          else
            sum_by_kind(ordinary, kind)
          end

        {key, amount}
      end)

    late_map =
      Map.new(@credit_movement_keys, fn {kind, key} ->
        amount =
          if kind == "expired" do
            sum_by_kind(late, "expired_restore")
          else
            sum_by_kind(late, kind)
          end

        {key, amount}
      end)

    credit_map = %{
      "opening_liability_cents" => opening,
      "movements" => movements_map,
      "closing_liability_cents" => closing
    }

    {credit_map, late_map}
  end

  # The expiry movements on the calendar: for every lot not already expired
  # when reporting started, the unused remainder frozen at its boundary (the
  # date after `expires_on`). The frozen amount is reconstructed from the
  # lot's current remainder plus entitlement revocations that happened after
  # the boundary (dormant, since the remainder had already left liability),
  # minus restorations after the boundary, whose expiry was itself recorded
  # on their own posting dates. A lot issued by an operation whose posting
  # date a close moved past the true boundary expires on its posting day
  # instead: the liability cannot leave an open report before it ever
  # appeared in one.
  defp boundary_expiries(movements, starts_on) do
    lots = Repo.all(from l in CreditLot, select: [:id, :amount_cents, :expires_on])
    applied = applied_by_lot()

    dormant = sums_by_lot(movements, "revoked_dormant")
    restored = sums_by_lot(movements, "expired_restore")
    issued_postings = issued_posting_by_lot(movements)

    lots
    |> Enum.filter(&(Date.compare(&1.expires_on, starts_on) != :lt))
    |> Enum.map(fn lot ->
      remainder = lot.amount_cents - Map.get(applied, lot.id, 0)

      amount =
        remainder + Map.get(dormant, lot.id, 0) - Map.get(restored, lot.id, 0)

      boundary =
        case Map.get(issued_postings, lot.id) do
          nil -> Date.add(lot.expires_on, 1)
          posting -> later(Date.add(lot.expires_on, 1), posting)
        end

      {boundary, amount}
    end)
    |> Enum.filter(fn {_boundary_date, amount} -> amount != 0 end)
    |> Enum.reduce(%{}, fn {boundary_date, amount}, totals ->
      Map.update(totals, boundary_date, amount, &(&1 + amount))
    end)
  end

  # The posting date of each lot's issuance, for lots created by an operation
  # processed after reporting started. Lots from the opening position carry
  # no issuance row and keep their true boundary.
  defp issued_posting_by_lot(movements) do
    movements
    |> Enum.filter(&(&1.kind == "issued" and not is_nil(&1.credit_lot_id)))
    |> Map.new(&{&1.credit_lot_id, &1.posting_date})
  end

  defp applied_by_lot do
    from(a in CreditApplication,
      group_by: a.credit_lot_id,
      select: {a.credit_lot_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp sums_by_lot(movements, kind) do
    movements
    |> Enum.filter(&(&1.kind == kind and not is_nil(&1.credit_lot_id)))
    |> Enum.reduce(%{}, fn movement, totals ->
      Map.update(
        totals,
        movement.credit_lot_id,
        movement.amount_cents,
        &(&1 + movement.amount_cents)
      )
    end)
  end

  defp signed_credit(rows, :before, date) do
    signed_credit(Enum.filter(rows, &before_day?(&1.posting_date, date)))
  end

  defp signed_credit(rows) do
    Enum.reduce(rows, 0, fn row, total ->
      total + @credit_signs[row.kind] * row.amount_cents
    end)
  end

  defp derived_before(boundaries, date) do
    boundaries
    |> Enum.filter(fn {boundary_date, _amount} -> before_day?(boundary_date, date) end)
    |> Enum.reduce(0, fn {_boundary_date, amount}, total -> total + amount end)
  end

  ## cash rows

  # The cash rows per property and the day's late cash adjustments: opening
  # held, the day's ordinary movements, and closing held. A property joins
  # the report once any opening snapshot or movement names it, and stays only
  # while any figure (opening, closing, ordinary, or late) is nonzero.
  defp cash_rows(date, movements) do
    cash = Enum.filter(movements, &Map.has_key?(@cash_signs, &1.kind))

    opening_cash =
      Repo.all(OpeningCash)
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    properties =
      (Map.keys(opening_cash) ++ Enum.map(cash, & &1.property_id))
      |> Enum.uniq()

    rows =
      Enum.map(properties, fn property_id ->
        property_rows = Enum.filter(cash, &(&1.property_id == property_id))
        on_date = Enum.filter(property_rows, &same_day?(&1.posting_date, date))
        {ordinary, late} = Enum.split_with(on_date, &(not &1.late_adjustment))

        opening =
          Map.get(opening_cash, property_id, 0) + signed_cash(property_rows, :before, date)

        closing = opening + signed_cash(on_date)

        ordinary_row = %{
          "property_id" => property_id,
          "opening_held_cents" => opening,
          "movements" => cash_sums(ordinary),
          "closing_held_cents" => closing
        }

        late_row = %{"property_id" => property_id, "movements" => cash_sums(late)}

        {ordinary_row, late_row}
      end)

    ordinary_rows =
      rows
      |> Enum.filter(fn {ordinary_row, late_row} ->
        ordinary_row["opening_held_cents"] != 0 or ordinary_row["closing_held_cents"] != 0 or
          any_movement?(ordinary_row["movements"]) or any_movement?(late_row["movements"])
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(& &1["property_id"])

    late_rows =
      rows
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&any_movement?(&1["movements"]))
      |> Enum.sort_by(& &1["property_id"])

    {ordinary_rows, late_rows}
  end

  defp cash_sums(rows) do
    Map.new(@cash_movement_keys, fn {kind, key} ->
      {key, sum_by_kind(rows, kind)}
    end)
  end

  defp any_movement?(movements) do
    Enum.any?(movements, fn {_key, amount} -> amount != 0 end)
  end

  defp signed_cash(rows, :before, date) do
    signed_cash(Enum.filter(rows, &before_day?(&1.posting_date, date)))
  end

  defp signed_cash(rows) do
    Enum.reduce(rows, 0, fn row, total ->
      total + @cash_signs[row.kind] * row.amount_cents
    end)
  end

  defp sum_by_kind(rows, kind) do
    rows
    |> Enum.filter(&(&1.kind == kind))
    |> sum_amounts()
  end

  defp sum_amounts(rows) do
    Enum.reduce(rows, 0, &(&1.amount_cents + &2))
  end

  defp same_day?(a, b), do: Date.compare(a, b) == :eq
  defp before_day?(a, b), do: Date.compare(a, b) == :lt
end
