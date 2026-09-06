defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  Reporting begins with the first applied `start_finance_reporting`
  operation. The financial state immediately before that operation is
  processed becomes the opening position on `starts_on`: the held cash of
  every property, the company-wide credit liability, and each credit lot
  still unexpired on `starts_on` with its remaining balance.

  Every applied operation processed after reporting started records its
  finance effects as movements posted on the later of its `occurred_on` and
  `starts_on`; all effects of one operation share the same posting date.
  Rejected operations record nothing, and a durable retry returns its stored
  result without recording again.

  A period close publishes every report through its cutoff: those reports are
  materialized with `status: "closed"` and served from their stored form, so
  their data stays byte-for-byte stable across later operations, later
  closes, and process restarts. An operation processed after a close posts on
  the later of its natural posting date and the first open day; when the
  close moved the date forward, its movements are reported as late
  adjustments on the day they post. An operation keeps the posting date
  chosen when it commits.

  A daily report is a pure read: the opening position plus the movements
  through the requested date. Credit that remains unused through its expiry
  date expires on that date, and a report shows that expiry even when no
  partner operation was submitted that day.
  """

  import Ecto.Query

  alias GroupStay.Finance.{Close, ClosedReport, Movement, OpeningCash, OpeningLot, Start}
  alias GroupStay.Groups.{CashAllocation, CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  # The start row is a singleton; the fixed primary key is what makes a
  # concurrent second start fail instead of committing.
  @singleton_id "00000000-0000-0000-0000-000000000001"

  # How each cash movement kind affects the held cash of its property.
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

  # How each credit movement kind affects the company-wide liability.
  @credit_signs %{
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  # The movement kinds that change a credit lot's remaining balance, used to
  # reconstruct how much of a lot is left when it expires.
  @remaining_signs %{
    "issued" => 1,
    "credit_applied" => -1,
    "credit_restored" => 1,
    "revoked" => -1
  }

  @doc """
  The applied finance-reporting start, or `nil` when reporting has not
  started.
  """
  def start, do: Repo.get(Start, @singleton_id)

  def started?, do: start() != nil

  @doc """
  The latest successful close, or `nil` when no period has been closed.

  Closes are strictly increasing, so the greatest cutoff is the latest close.
  """
  def latest_close do
    Repo.one(from c in Close, order_by: [desc: c.period_end_on], limit: 1)
  end

  @doc """
  The first open day: the day after the latest cutoff, or `nil` when no
  period has been closed.
  """
  def first_open_day do
    case latest_close() do
      nil -> nil
      %Close{period_end_on: cutoff} -> Date.add(cutoff, 1)
    end
  end

  @doc """
  The reporting posting date for an operation with the given `occurred_on`:
  the later of `occurred_on`, `starts_on`, and the first open day at the
  moment the operation commits. Returns `nil` when reporting has not started.
  """
  def posting_date(%Date{} = occurred_on) do
    case posting_info(occurred_on) do
      nil -> nil
      %{posting_date: posting_date} -> posting_date
    end
  end

  @doc """
  The posting date an operation's movements commit on, and whether a close
  moved that date forward. The natural posting date is the later of
  `occurred_on` and `starts_on`; when a period is closed, an operation whose
  natural date is not in the open period posts on the first open day instead,
  and its movements are late adjustments. Returns `nil` when reporting has
  not started.
  """
  def posting_info(%Date{} = occurred_on) do
    case start() do
      nil ->
        nil

      %Start{starts_on: starts_on} ->
        natural = later_of(occurred_on, starts_on)

        case first_open_day() do
          nil ->
            %{posting_date: natural, late_adjustment: false}

          first_open ->
            posting_date = later_of(natural, first_open)

            %{
              posting_date: posting_date,
              late_adjustment: Date.compare(posting_date, natural) == :gt
            }
        end
    end
  end

  @doc """
  Records the finance movements of an applied operation, unless reporting
  has not started. All movements of one operation share its posting date and
  its late-adjustment status. Zero-amount movements are omitted.
  """
  def record_movements(%Date{} = occurred_on, movements) do
    movements = Enum.reject(movements, fn movement -> movement.amount_cents == 0 end)

    case movements do
      [] ->
        :ok

      movements ->
        case posting_info(occurred_on) do
          nil ->
            :ok

          %{posting_date: posting_date, late_adjustment: late_adjustment} ->
            Enum.each(movements, fn movement ->
              %Movement{}
              |> Movement.create_changeset(%{
                posting_date: posting_date,
                kind: movement.kind,
                amount_cents: movement.amount_cents,
                property_id: Map.get(movement, :property_id),
                credit_lot_id: Map.get(movement, :credit_lot_id),
                late_adjustment: late_adjustment
              })
              |> Repo.insert!()
            end)
        end
    end
  end

  @doc """
  Enables finance reporting with the financial state immediately before the
  start operation as the opening position on `starts_on`.

  Runs inside the start operation's transaction. A concurrent start that
  commits first rolls this attempt back with `:reporting_start_race`.
  """
  def start_reporting!(%Date{} = starts_on) do
    changeset =
      Start.create_changeset(%Start{}, %{
        id: @singleton_id,
        starts_on: starts_on,
        opening_credit_liability_cents: opening_credit_liability(starts_on)
      })

    case Repo.insert(changeset) do
      {:ok, _start} ->
        insert_opening_cash!()
        insert_opening_lots!(starts_on)
        :ok

      {:error, _changeset} ->
        Repo.rollback(:reporting_start_race)
    end
  end

  # The credit liability immediately before the start operation, evaluated as
  # of `starts_on`: unexpired lot balances plus credit applied to active
  # groups.
  defp opening_credit_liability(starts_on) do
    unexpired =
      Repo.aggregate(
        from(l in CreditLot, where: l.expires_on > ^starts_on),
        :sum,
        :remaining_cents
      ) || 0

    held =
      Repo.aggregate(
        from(a in CreditAllocation, where: a.state == "held"),
        :sum,
        :amount_cents
      ) || 0

    unexpired + held
  end

  defp insert_opening_cash! do
    Repo.all(
      from a in CashAllocation,
        where: a.state == "held",
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == r.group_id,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Enum.each(fn {property_id, amount_cents} ->
      %OpeningCash{}
      |> OpeningCash.create_changeset(%{property_id: property_id, amount_cents: amount_cents})
      |> Repo.insert!()
    end)
  end

  defp insert_opening_lots!(starts_on) do
    Repo.all(from l in CreditLot, where: l.expires_on > ^starts_on)
    |> Enum.each(fn lot ->
      %OpeningLot{}
      |> OpeningLot.create_changeset(%{
        credit_lot_id: lot.id,
        remaining_cents: lot.remaining_cents
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Closes the finance period through `period_end_on`.

  Every report from the previous cutoff (or `starts_on`) through
  `period_end_on` is materialized with `status: "closed"` and stored under
  its date; from then on it is served from its stored form. Runs inside the
  close operation's transaction. A concurrent close that commits an equal or
  conflicting cutoff rolls this attempt back with `:period_close_race`.
  """
  def close_period!(%Date{} = period_end_on) do
    %Start{} = start = start()

    first_date =
      case latest_close() do
        nil -> start.starts_on
        %Close{period_end_on: cutoff} -> Date.add(cutoff, 1)
      end

    Enum.each(Date.range(first_date, period_end_on), fn date ->
      report = build_report(start, date, "closed")

      case Repo.insert(
             ClosedReport.create_changeset(%ClosedReport{}, %{date: date, data: report})
           ) do
        {:ok, _report} -> :ok
        {:error, _changeset} -> Repo.rollback(:period_close_race)
      end
    end)

    changeset = Close.create_changeset(%Close{}, %{period_end_on: period_end_on})

    case Repo.insert(changeset) do
      {:ok, _close} -> :ok
      {:error, _changeset} -> Repo.rollback(:period_close_race)
    end
  end

  @doc """
  The daily finance report for `date`.

  Returns `{:error, :report_not_available}` before reporting has started or
  for a date before `starts_on`. A date through the latest cutoff is served
  from its stored form, byte-for-byte stable. Reading a report never changes
  a report or any domain state.
  """
  def daily_report(%Date{} = date) do
    case start() do
      nil ->
        {:error, :report_not_available}

      %Start{} = start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get(ClosedReport, date) do
            nil -> {:ok, build_report(start, date, "open")}
            %ClosedReport{data: data} -> {:ok, data}
          end
        end
    end
  end

  defp build_report(%Start{} = start, date, status) do
    movements = Repo.all(from m in Movement, where: m.posting_date <= ^date)
    {cash, late_cash} = cash_section(date, movements)
    {credit, late_credit} = credit_section(start, date, movements)

    %{
      date: date,
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  # Cash entries

  defp cash_section(date, movements) do
    opening =
      OpeningCash
      |> Repo.all()
      |> Map.new(fn opening -> {opening.property_id, opening.amount_cents} end)

    cash_movements = Enum.filter(movements, &(&1.property_id != nil))

    {entries, late_entries} =
      (Map.keys(opening) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn property, {entries, late_entries} ->
        {entry, late_entry} =
          cash_entry(property, Map.get(opening, property, 0), date, cash_movements)

        entries = if entry, do: [entry | entries], else: entries
        late_entries = if late_entry, do: [late_entry | late_entries], else: late_entries
        {entries, late_entries}
      end)

    {Enum.reverse(entries), Enum.reverse(late_entries)}
  end

  # A property is omitted from the cash array only when its opening balance,
  # closing balance, and every movement of the day (ordinary plus late
  # adjustment) are zero. It is omitted from the late-adjustment cash array
  # when all of its late-adjustment values are zero.
  defp cash_entry(property, opening_snapshot, date, cash_movements) do
    own = Enum.filter(cash_movements, &(&1.property_id == property))
    {before, today} = split_by_date(own, date)
    {today_late, today_ordinary} = split_late(today)

    opening = opening_snapshot + cash_net(before)
    ordinary = kind_totals(Movement.cash_kinds(), today_ordinary)
    late = kind_totals(Movement.cash_kinds(), today_late)
    closing = opening + cash_net(today_ordinary) + cash_net(today_late)

    entry =
      if opening == 0 and closing == 0 and
           Enum.all?(Map.values(ordinary), &(&1 == 0)) and
           Enum.all?(Map.values(late), &(&1 == 0)) do
        nil
      else
        %{
          property_id: property,
          opening_held_cents: opening,
          movements: movement_map(Movement.cash_kinds(), ordinary),
          closing_held_cents: closing
        }
      end

    late_entry =
      if Enum.all?(Map.values(late), &(&1 == 0)) do
        nil
      else
        %{property_id: property, movements: movement_map(Movement.cash_kinds(), late)}
      end

    {entry, late_entry}
  end

  defp cash_net(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      total + movement.amount_cents * Map.fetch!(@cash_signs, movement.kind)
    end)
  end

  # Credit entry

  defp credit_section(%Start{} = start, date, movements) do
    credit_movements =
      Enum.filter(movements, &(&1.kind in Movement.credit_kinds())) ++
        time_based_expiries(start, date, movements)

    {before, today} = split_by_date(credit_movements, date)
    {today_late, today_ordinary} = split_late(today)

    opening = start.opening_credit_liability_cents + credit_net(before)
    ordinary = kind_totals(Movement.credit_kinds(), today_ordinary)
    late = kind_totals(Movement.credit_kinds(), today_late)
    closing = opening + credit_net(today_ordinary) + credit_net(today_late)

    {
      %{
        opening_liability_cents: opening,
        movements: movement_map(Movement.credit_kinds(), ordinary),
        closing_liability_cents: closing
      },
      movement_map(Movement.credit_kinds(), late)
    }
  end

  defp credit_net(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      total + movement.amount_cents * Map.fetch!(@credit_signs, movement.kind)
    end)
  end

  # Credit that remains unused through its expiry date expires on that date,
  # even when no partner operation was submitted that day. A lot issued by an
  # operation processed after reporting started never expires before its
  # issuance posts: before `starts_on`, and when a close moved the issuance
  # forward, the expiry moves with it.
  defp time_based_expiries(%Start{} = start, date, movements) do
    opening_by_lot =
      OpeningLot
      |> Repo.all()
      |> Map.new(fn opening -> {opening.credit_lot_id, opening.remaining_cents} end)

    issued_by_lot =
      for m <- movements,
          m.kind == "issued",
          m.credit_lot_id != nil,
          into: %{} do
        {m.credit_lot_id, m.posting_date}
      end

    case Enum.uniq(Map.keys(opening_by_lot) ++ Map.keys(issued_by_lot)) do
      [] ->
        []

      lot_ids ->
        Repo.all(from l in CreditLot, where: l.id in ^lot_ids)
        |> Enum.flat_map(fn lot ->
          issued_on = Map.get(issued_by_lot, lot.id, start.starts_on)
          expiry_date = later_of(lot.expires_on, issued_on)

          if Date.compare(expiry_date, date) == :gt do
            []
          else
            base = Map.get(opening_by_lot, lot.id, 0)

            case remaining_before_expiry(lot.id, base, movements, expiry_date) do
              0 -> []
              amount -> [%{posting_date: expiry_date, kind: "expired", amount_cents: amount}]
            end
          end
        end)
    end
  end

  # The lot's remaining balance immediately before its expiry: its opening
  # balance (none for a lot issued after reporting started) plus every
  # recorded balance change posted before the expiry, and the lot's own
  # issuance when it posts on the expiry date itself.
  defp remaining_before_expiry(lot_id, base, movements, expiry_date) do
    movements
    |> Enum.filter(&(&1.credit_lot_id == lot_id and Map.has_key?(@remaining_signs, &1.kind)))
    |> Enum.reduce(base, fn movement, remaining ->
      cond do
        Date.compare(movement.posting_date, expiry_date) == :lt ->
          remaining + movement.amount_cents * Map.fetch!(@remaining_signs, movement.kind)

        movement.kind == "issued" and
            Date.compare(movement.posting_date, expiry_date) == :eq ->
          remaining + movement.amount_cents

        true ->
          remaining
      end
    end)
  end

  # Shared helpers

  defp split_by_date(movements, date) do
    Enum.split_with(movements, fn movement ->
      Date.compare(movement.posting_date, date) == :lt
    end)
  end

  # Late adjustments are movements whose posting date a close moved forward.
  # Time-based expiries are synthetic maps without the flag and are never
  # late adjustments.
  defp split_late(movements) do
    Enum.split_with(movements, &(Map.get(&1, :late_adjustment, false) == true))
  end

  defp kind_totals(kinds, movements) do
    base = Map.new(kinds, &{&1, 0})

    Enum.reduce(movements, base, fn movement, acc ->
      Map.update!(acc, movement.kind, &(&1 + movement.amount_cents))
    end)
  end

  defp movement_map(kinds, totals) do
    Map.new(kinds, fn kind ->
      {String.to_atom(kind <> "_cents"), Map.fetch!(totals, kind)}
    end)
  end

  defp later_of(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end
end
