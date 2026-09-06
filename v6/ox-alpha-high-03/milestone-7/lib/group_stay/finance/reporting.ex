defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  The durable daily finance report.

  The first applied `start_finance_reporting` operation captures the current
  financial state - held cash per property and the company-wide credit
  liability - as the opening position on `starts_on`. Every operation applied
  afterwards records its finance effects here as signed movements on the
  posting date, the later of the operation's `occurred_on` and `starts_on`.
  Credit that remains unused expires implicitly on its lot's `expires_on`
  date and is computed at read time so the report shows it even when no
  partner operation was submitted that day.

  A successful `close_finance_period` operation snapshots every daily report
  through its cutoff as published data and moves the reporting posting date
  of later operations onto the first open day when their own date falls in a
  closed period.

  Reports are derived read-only views: reading them never changes a report or
  any domain state.
  """

  import Ecto.Query

  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.ReportMovement
  alias GroupStay.Finance.ReportOpening
  alias GroupStay.Finance.ReportingStart
  alias GroupStay.Bookings.Group
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.ReportSnapshot
  alias GroupStay.Repo

  @cash_classifications ~w(
    received_cents transferred_in_cents transferred_out_cents refunded_cents
    retained_cents converted_to_credit_cents reduced_cents charged_back_cents
  )

  @credit_classifications ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  @doc """
  Parses an ISO 8601 calendar date supplied for reporting purposes.
  """
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> {:error, :invalid_reporting_date}
    end
  end

  def parse_date(_value), do: {:error, :invalid_reporting_date}

  @doc """
  Whether finance reporting has started.
  """
  def started?, do: Repo.exists?(ReportingStart)

  @doc """
  The date reporting starts on, or nil before the first applied start operation.
  """
  def starts_on do
    case Repo.one(ReportingStart) do
      nil -> nil
      start -> start.starts_on
    end
  end

  @doc """
  The inclusive cutoff of the latest successful close, or nil when no period
  has been closed yet.
  """
  def latest_cutoff do
    from(c in PeriodClose, select: max(c.period_end_on)) |> Repo.one()
  end

  @doc """
  The first day of the open period - the day after the latest cutoff - or nil
  while no close exists.
  """
  def first_open_day do
    case latest_cutoff() do
      nil -> nil
      cutoff -> Date.add(cutoff, 1)
    end
  end

  @doc """
  Enables reporting and captures the financial state immediately before this
  call as the opening position. Runs inside the caller's transaction; later
  operations in the same batch record movements instead of changing it.
  """
  def start!(starts_on) do
    captured_on = Date.utc_today()

    Repo.insert!(%ReportingStart{starts_on: starts_on, captured_on: captured_on})

    from(m in CashMovement,
      join: g in Group,
      on: g.id == m.group_id,
      where: m.kind == "held",
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(m.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, amount_cents} ->
      Repo.insert!(%ReportOpening{
        kind: "cash_held",
        property_id: property_id,
        amount_cents: amount_cents
      })
    end)

    Repo.insert!(%ReportOpening{
      kind: "credit_liability",
      property_id: nil,
      amount_cents: GroupStay.Finance.credit_liability(captured_on)
    })

    :ok
  end

  @doc """
  Records report movements for one posting date. Entries are
  `{classification, property_id | nil, signed_amount_cents}` tuples with cash
  classifications attributed to a property and credit classifications
  company-wide. Logging is a no-op before reporting has started or when the
  posting date is nil, and zero amounts are never recorded. `late?` marks the
  entries as moved forward by a period close onto the first open day.
  """
  def log(posting_date, entries, late? \\ false)

  def log(nil, _entries, _late?), do: :ok

  def log(posting_date, entries, late?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      entries
      |> Enum.reject(fn {_classification, _property_id, amount_cents} -> amount_cents == 0 end)
      |> Enum.map(fn {classification, property_id, amount_cents} ->
        %{
          posting_date: posting_date,
          property_id: property_id,
          classification: classification,
          amount_cents: amount_cents,
          late_adjustment: late?,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(ReportMovement, rows)

    :ok
  end

  @doc """
  Closes the finance period through `period_end_on`: every daily report from
  `starts_on` through the cutoff is snapshotted verbatim as published data,
  and the cutoff is recorded so later operations post onto the first open
  day. Runs inside the caller's transaction.
  """
  def close!(period_end_on) do
    starts_on = starts_on()

    # Earlier closes already snapshotted everything through their cutoffs;
    # only the newly covered days are published now.
    from_date =
      case latest_cutoff() do
        nil -> starts_on
        cutoff -> Date.add(cutoff, 1)
      end

    Date.range(from_date, period_end_on)
    |> Enum.each(fn date ->
      data =
        date
        |> build_report(starts_on)
        |> Map.put("status", "closed")
        |> Jason.encode!()

      Repo.insert!(%ReportSnapshot{report_date: date, data: data})
    end)

    Repo.insert!(%PeriodClose{period_end_on: period_end_on})

    :ok
  end

  @doc """
  The report for one day, or `:not_available` before reporting has started or
  for a date before `starts_on`. A date covered by a close returns its stored
  published snapshot unchanged.
  """
  def daily_report(date) do
    case snapshot_for(date) do
      %ReportSnapshot{} = snapshot ->
        {:ok, Jason.decode!(snapshot.data)}

      nil ->
        case starts_on() do
          nil ->
            :not_available

          starts_on ->
            if Date.compare(date, starts_on) == :lt do
              :not_available
            else
              {:ok, build_report(date, starts_on)}
            end
        end
    end
  end

  defp snapshot_for(date) do
    Repo.get_by(ReportSnapshot, report_date: date)
  end

  defp build_report(date, starts_on) do
    rows =
      from(m in ReportMovement,
        where: m.posting_date >= ^starts_on and m.posting_date <= ^date,
        select:
          {m.posting_date, m.property_id, m.classification, m.amount_cents, m.late_adjustment}
      )
      |> Repo.all()

    {past_rows, day_rows} =
      Enum.split_with(rows, fn {posting_date, _property_id, _classification, _amount, _late?} ->
        Date.compare(posting_date, date) == :lt
      end)

    {ordinary_day_rows, late_day_rows} =
      Enum.split_with(day_rows, fn {_p, _pr, _c, _a, late?} -> not late? end)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_entries(past_rows, ordinary_day_rows, late_day_rows),
      "credit" => credit_entry(past_rows, ordinary_day_rows, late_day_rows, starts_on, date),
      "late_adjustments" => late_adjustments(late_day_rows)
    }
  end

  defp cash_entries(past_rows, day_rows, late_day_rows) do
    openings = cash_openings()
    past = cash_sums(past_rows)
    current = cash_sums(day_rows)
    late_current = cash_sums(late_day_rows)

    MapSet.union(MapSet.new(Map.keys(openings)), MapSet.new(Map.keys(past)))
    |> MapSet.union(MapSet.new(Map.keys(current)))
    |> MapSet.union(MapSet.new(Map.keys(late_current)))
    |> Enum.sort()
    |> Enum.flat_map(fn property_id ->
      # The opening position of a day is the captured position plus every
      # movement posted on earlier reporting dates.
      opening_held_cents =
        Map.get(openings, property_id, 0) + held_delta(Map.get(past, property_id, %{}))

      movements = Map.get(current, property_id, %{})
      late_movements = Map.get(late_current, property_id, %{})
      # Balances use both ordinary and late-adjusted movements.
      closing_held_cents =
        closing_held(opening_held_cents, movements) +
          held_delta(Map.get(late_current, property_id, %{}))

      if opening_held_cents == 0 and closing_held_cents == 0 and all_zero?(movements) and
           all_zero?(late_movements) do
        []
      else
        [
          %{
            "property_id" => property_id,
            "opening_held_cents" => opening_held_cents,
            "movements" => movement_object(@cash_classifications, movements),
            "closing_held_cents" => closing_held_cents
          }
        ]
      end
    end)
  end

  defp cash_sums(rows) do
    Enum.reduce(rows, %{}, fn {_posting_date, property_id, classification, amount, _late?}, acc ->
      if is_nil(property_id) do
        acc
      else
        Map.update(acc, property_id, %{classification => amount}, fn movements ->
          Map.update(movements, classification, amount, &(&1 + amount))
        end)
      end
    end)
  end

  # Movements moved forward by a close onto the first open day. Reported
  # separately from the ordinary movements; the day's totals are the sum of
  # both. Properties whose late adjustments are all zero are omitted and the
  # array is ordered by property id.
  defp late_adjustments(late_day_rows) do
    %{
      "cash" =>
        late_day_rows
        |> cash_sums()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reject(fn {_property_id, movements} -> all_zero?(movements) end)
        |> Enum.map(fn {property_id, movements} ->
          %{
            "property_id" => property_id,
            "movements" => movement_object(@cash_classifications, movements)
          }
        end),
      "credit" => movement_object(@credit_classifications, credit_sums(late_day_rows))
    }
  end

  defp held_delta(movements) do
    get(movements, "received_cents") + get(movements, "transferred_in_cents") -
      get(movements, "transferred_out_cents") - get(movements, "refunded_cents") -
      get(movements, "retained_cents") - get(movements, "converted_to_credit_cents") -
      get(movements, "reduced_cents") - get(movements, "charged_back_cents")
  end

  defp closing_held(opening, movements) do
    opening + held_delta(movements)
  end

  defp credit_entry(past_rows, day_rows, late_day_rows, starts_on, date) do
    past = credit_sums(past_rows)
    current = credit_sums(day_rows)

    # Credit that quietly expired on earlier reporting dates also belongs to
    # today's opening liability.
    expired_before_date = expiring_credit_between(starts_on, Date.add(date, -1))
    past = Map.update(past, "expired_cents", expired_before_date, &(&1 + expired_before_date))

    # Implicit expiry is never a late adjustment; only movements whose posting
    # date was moved forward by a close belong to the late bucket.
    expired_on_date = expiring_credit_between(date, date)
    current = Map.update(current, "expired_cents", expired_on_date, &(&1 + expired_on_date))

    # Across a close the previous day's liability is frozen, so an open day
    # chains its opening from the stored snapshot rather than recomputing
    # history whose inputs later operations may have changed retroactively.
    opening_liability_cents =
      case snapshot_for(Date.add(date, -1)) do
        %ReportSnapshot{data: data} when is_binary(data) ->
          data
          |> Jason.decode!()
          |> Map.fetch!("credit")
          |> Map.fetch!("closing_liability_cents")

        _nil ->
          credit_opening() + liability_delta(past)
      end

    closing_liability_cents =
      opening_liability_cents + liability_delta(current) +
        liability_delta(credit_sums(late_day_rows))

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => movement_object(@credit_classifications, current),
      "closing_liability_cents" => closing_liability_cents
    }
  end

  defp credit_sums(rows) do
    Enum.reduce(rows, %{}, fn {_posting_date, property_id, classification, amount, _late?}, acc ->
      if is_nil(property_id) do
        Map.update(acc, classification, amount, &(&1 + amount))
      else
        acc
      end
    end)
  end

  defp liability_delta(movements) do
    get(movements, "issued_cents") - get(movements, "expired_cents") -
      get(movements, "consumed_cents") - get(movements, "revoked_cents") -
      get(movements, "absorbed_cents")
  end

  # Credit unused through its availability expires on its stored `expires_on`
  # date. Lots already past expiry when the opening position was captured are
  # skipped: their liability was never part of it. Later clawbacks adjust a
  # lot's remaining balance retroactively, which is how a later submission may
  # change an earlier open report.
  defp expiring_credit_between(from_date, to_date) do
    case Repo.one(ReportingStart) do
      nil ->
        0

      start ->
        lower =
          if Date.compare(start.captured_on, from_date) == :lt do
            from_date
          else
            Date.add(start.captured_on, 1)
          end

        if Date.compare(lower, to_date) == :gt do
          0
        else
          from(l in CreditLot,
            where: l.expires_on >= ^lower and l.expires_on <= ^to_date,
            select: coalesce(sum(l.remaining_cents), 0)
          )
          |> Repo.one()
          |> Kernel.||(0)
        end
    end
  end

  defp cash_openings do
    from(o in ReportOpening,
      where: o.kind == "cash_held",
      select: {o.property_id, o.amount_cents}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp credit_opening do
    from(o in ReportOpening,
      where: o.kind == "credit_liability",
      select: coalesce(sum(o.amount_cents), 0)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp movement_object(classifications, movements) do
    Map.new(classifications, fn classification ->
      {classification, get(movements, classification)}
    end)
  end

  defp all_zero?(movements) do
    Enum.all?(Map.values(movements), &(&1 == 0))
  end

  defp get(movements, classification), do: Map.get(movements, classification, 0)
end
