defmodule GroupStay.Finance do
  @moduledoc """
  The durable reporting inception point and the daily finance report.

  `start_reporting/1` captures the financial state immediately before the
  first applied start operation — cash held per property and each credit
  lot's available balance — as the opening position on `starts_on`. Every
  applied operation processed after that point posts its finance effects as
  signed movement rows at its reporting posting date: the later of its
  `occurred_on` and `starts_on`, or once a period close exists, at least the
  first open day after that close. Operations processed before the start post
  nothing: their effects are already inside the opening position. A posting
  pushed forward by a close is flagged late so reports can surface it as a
  late adjustment; the flag never changes what the movement means.

  A day's report is a pure aggregation of the opening position plus the
  movements posted up to and on that day. Reading reports never changes
  state, reading in any order yields the same numbers, and a later submission
  revises an earlier open day simply by appending rows at its posting date.
  Because every posting lands beyond the published frontier, closed days
  never change again.

  Expiry is never an operation, so each lot's expiry movement is derived for
  any date from the lot's opening baseline and its recorded application,
  restoration, and revocation movements posted strictly before the lot's own
  `expires_on` — which lets the report show expiry even when no partner
  operation was submitted that day, keeps the figure stable once the day is
  published, and stops forwarded postings from disturbing an already-expired
  lot's books.

  `close_through/1` publishes every report through a cutoff: each day's
  rendered JSON is frozen into a snapshot that the endpoint serves verbatim
  forever after, and the cutoff row becomes the frontier later closes must
  move strictly past.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditMovement
  alias GroupStay.Finance.LotOpening
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.PropertyOpening
  alias GroupStay.Finance.ReportingSettings
  alias GroupStay.Finance.ReportSnapshot
  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  # Movement kinds are stored exactly as the daily-report columns name them.
  @cash_kinds ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  @credit_kinds ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  # How one reported unit of each cash kind changes held cash.
  @cash_held_effect %{
    received_cents: 1,
    transferred_in_cents: 1,
    transferred_out_cents: -1,
    refunded_cents: -1,
    retained_cents: -1,
    converted_to_credit_cents: -1,
    reduced_cents: -1,
    charged_back_cents: -1
  }

  # How one reported unit of each credit kind changes credit liability. The
  # internal kinds (`applied`, `restored`) move credit between available and
  # applied without changing the liability.
  @credit_liability_effect %{
    issued_cents: 1,
    expired_cents: -1,
    consumed_cents: -1,
    revoked_cents: -1,
    absorbed_cents: -1,
    applied: 0,
    restored: 0
  }

  # How one unit of each credit kind changes a lot's available balance. This
  # is what expiry derivation replays.
  @credit_available_effect %{
    issued_cents: 1,
    restored: 1,
    applied: -1,
    revoked_cents: -1,
    expired_cents: 0,
    consumed_cents: 0,
    absorbed_cents: 0
  }

  @type report_error :: {:error, :report_not_available}

  @doc """
  Enables finance reporting with `starts_on`, capturing the current financial
  state as the opening position.

  Returns `{:error, :reporting_already_started}` once an inception row exists;
  the caller's transaction makes the capture and the settings row atomic with
  the start operation's durable record.
  """
  def start_reporting(%Date{} = starts_on) do
    if started?() do
      {:error, :reporting_already_started}
    else
      %ReportingSettings{}
      |> ReportingSettings.changeset(%{
        singleton: 1,
        starts_on: starts_on,
        opening_credit_liability_cents: Credit.liability_cents(Date.utc_today())
      })
      |> Repo.insert()
      |> case do
        {:ok, _settings} ->
          capture_openings()
          :ok

        # A concurrent submission won the singleton index: nothing was
        # captured, so this transaction leaves no trace.
        {:error, _changeset} ->
          {:error, :reporting_already_started}
      end
    end
  end

  @doc """
  Whether finance reporting has started.
  """
  def started?, do: settings() != nil

  @doc """
  The reporting posting for an operation with the given `occurred_on`,
  returned as `{date, late?}`.

  The date is `max(occurred_on, starts_on, first open day)` — where the
  first open day is the day after the latest close at the moment the
  operation commits, so an operation immediately before a close posts into
  the period being closed and an old-dated operation immediately after it
  posts on the first open day. `late?` is true exactly when a close moved
  the date forward beyond that natural maximum; those postings surface as
  late adjustments. The date is `nil` for operations processed before
  reporting started (which post no movements at all).
  """
  def posting(%Date{} = occurred_on) do
    case settings() do
      nil ->
        {nil, false}

      %{starts_on: starts_on} ->
        natural =
          if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

        case latest_cutoff() do
          nil ->
            {natural, false}

          cutoff ->
            first_open_day = Date.add(cutoff, 1)

            if Date.compare(natural, first_open_day) == :lt do
              {first_open_day, true}
            else
              {natural, false}
            end
        end
    end
  end

  @doc """
  Appends one signed cash movement for the property, or does nothing when
  the posting date is nil (reporting had not started).
  """
  def record_cash(posting, property_id, kind, amount_cents)

  def record_cash({nil, _late?}, _property_id, _kind, _amount_cents), do: :ok

  def record_cash({%Date{} = posting_date, late?}, property_id, kind, amount_cents) do
    if amount_cents == 0 do
      :ok
    else
      Repo.insert!(%CashMovement{
        posting_date: posting_date,
        property_id: property_id,
        kind: Atom.to_string(kind),
        amount_cents: amount_cents,
        late: late?
      })

      :ok
    end
  end

  @doc """
  Appends one signed hotel-credit movement against the lot, or does nothing
  when the posting date is nil.
  """
  def record_credit(posting, credit_lot_id, kind, amount_cents)

  def record_credit({nil, _late?}, _credit_lot_id, _kind, _amount_cents), do: :ok

  def record_credit({%Date{} = posting_date, late?}, credit_lot_id, kind, amount_cents) do
    if amount_cents == 0 do
      :ok
    else
      Repo.insert!(%CreditMovement{
        posting_date: posting_date,
        credit_lot_id: credit_lot_id,
        kind: Atom.to_string(kind),
        amount_cents: amount_cents,
        late: late?
      })

      :ok
    end
  end

  @doc """
  The daily report for `date`, or `{:error, :report_not_available}` before
  reporting has started or for a date before `starts_on`.

  A published (closed) day returns `{:ok, {:published, data_json}}` where
  `data_json` is the exact JSON frozen when the close committed; open days
  return `{:ok, report}` freshly aggregated.
  """
  @spec daily_report(Date.t()) ::
          {:ok, map()} | {:ok, {:published, String.t()}} | report_error()
  def daily_report(%Date{} = date) do
    case settings() do
      nil ->
        {:error, :report_not_available}

      settings ->
        if Date.compare(date, settings.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get_by(ReportSnapshot, report_date: date) do
            nil ->
              {:ok, build_report(date, settings)}

            snapshot ->
              {:ok, {:published, snapshot.data_json}}
          end
        end
    end
  end

  @doc """
  Closes the finance period through `period_end_on`: every daily report from
  `starts_on` through the cutoff is published as a byte-for-byte stable
  snapshot with `status: "closed"`, and the cutoff becomes the frontier that
  posting dates must clear.

  Applies only once reporting has started, on or after `starts_on`, and
  strictly later than the latest successful close; anything else is
  `{:error, :invalid_period}`. Participates in the caller's transaction so
  the snapshots, the close row, and the operation's durable record commit
  atomically.
  """
  @spec close_through(Date.t()) :: :ok | {:error, :invalid_period}
  def close_through(%Date{} = period_end_on) do
    case settings() do
      nil ->
        {:error, :invalid_period}

      settings ->
        cond do
          Date.compare(period_end_on, settings.starts_on) == :lt ->
            {:error, :invalid_period}

          not strictly_after_latest?(period_end_on) ->
            {:error, :invalid_period}

          true ->
            publish_through(settings, period_end_on)

            %PeriodClose{}
            |> PeriodClose.changeset(%{period_end_on: period_end_on})
            |> Repo.insert!()

            :ok
        end
    end
  end

  # The cutoff of the latest successful close, or nil before any close.
  defp latest_cutoff do
    from(c in PeriodClose,
      order_by: [desc: c.period_end_on],
      limit: 1,
      select: c.period_end_on
    )
    |> Repo.one()
  end

  defp strictly_after_latest?(period_end_on) do
    case latest_cutoff() do
      nil -> true
      cutoff -> Date.compare(period_end_on, cutoff) == :gt
    end
  end

  # Freezes each day's rendered report through the cutoff. Days already
  # published by an earlier close keep their frozen snapshot untouched; a
  # close row is unique per cutoff and inserted right after, so a losing
  # concurrent close raises and takes its snapshots back out with its
  # transaction.
  defp publish_through(%ReportingSettings{} = settings, period_end_on) do
    published =
      from(s in ReportSnapshot, select: s.report_date)
      |> Repo.all()
      |> MapSet.new()

    Date.range(settings.starts_on, period_end_on)
    |> Enum.reject(&MapSet.member?(published, &1))
    |> Enum.each(fn date ->
      %ReportSnapshot{}
      |> ReportSnapshot.changeset(%{
        report_date: date,
        data_json:
          date
          |> build_report(settings)
          |> Map.put("status", "closed")
          |> Jason.encode!()
      })
      |> Repo.insert!()
    end)

    :ok
  end

  defp settings do
    Repo.one(from(s in ReportingSettings, limit: 1))
  end

  # Opening-position capture: held cash per property across active rooms, and
  # each lot's available balance — what it still holds beyond the amounts
  # applied to active groups, or zero once the lot has expired.
  defp capture_openings do
    property_cash_held()
    |> Enum.each(fn {property_id, cents} ->
      Repo.insert!(%PropertyOpening{property_id: property_id, cash_held_cents: cents})
    end)

    applied_by_lot = credit_applied_by_lot()

    Repo.all(Lot)
    |> Enum.each(fn lot ->
      applied = Map.get(applied_by_lot, lot.id, 0)

      available =
        if Date.compare(lot.expires_on, Date.utc_today()) == :gt,
          do: max(lot.remaining_cents - applied, 0),
          else: 0

      Repo.insert!(%LotOpening{credit_lot_id: lot.id, available_cents: available})
    end)

    :ok
  end

  defp build_report(date, settings) do
    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_section(date),
      "credit" => credit_section(date, settings),
      "late_adjustments" => late_adjustment_section(date)
    }
  end

  defp cash_section(date) do
    openings = property_openings()

    opening =
      cash_movements_before(date)
      |> Enum.reduce(openings, fn {property_id, kind, amount, _late?}, acc ->
        delta = Map.fetch!(@cash_held_effect, kind) * amount
        Map.update(acc, property_id, delta, &(&1 + delta))
      end)

    ordinary_sums =
      date
      |> cash_movements_on(false)
      |> sum_cash_by_property()

    late_sums =
      date
      |> cash_movements_on(true)
      |> sum_cash_by_property()

    properties =
      [Map.keys(opening), property_ids(ordinary_sums), property_ids(late_sums)]
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening_held_cents = Map.get(opening, property_id, 0)
      movements = cash_movement_map(ordinary_sums, property_id)
      late_movements = cash_movement_map(late_sums, property_id)

      closing_held_cents =
        opening_held_cents + held_effect_total(movements) + held_effect_total(late_movements)

      any_movement? =
        Enum.any?(Map.values(movements), &(&1 != 0)) or
          Enum.any?(Map.values(late_movements), &(&1 != 0))

      if opening_held_cents != 0 or closing_held_cents != 0 or any_movement? do
        [
          %{
            "property_id" => property_id,
            "opening_held_cents" => opening_held_cents,
            "movements" => stringify_kinds(movements),
            "closing_held_cents" => closing_held_cents
          }
        ]
      else
        []
      end
    end)
  end

  # Late adjustments carry only the movements whose posting date a close
  # moved forward: no balances, ordered by property, all-zero properties
  # omitted, and the credit object always present. Each day's total movement
  # is its ordinary value plus this block's value.
  defp late_adjustment_section(date) do
    late_sums =
      date
      |> cash_movements_on(true)
      |> sum_cash_by_property()

    cash =
      late_sums
      |> property_ids()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn property_id ->
        movements = cash_movement_map(late_sums, property_id)

        if Enum.any?(Map.values(movements), &(&1 != 0)) do
          [%{"property_id" => property_id, "movements" => stringify_kinds(movements)}]
        else
          []
        end
      end)

    %{"cash" => cash, "credit" => late_credit_movements(date)}
  end

  defp credit_section(date, settings) do
    before = credit_movements_before(date)
    ordinary_on = credit_movements_on(date, false)
    late_on = credit_movements_on(date, true)

    derived = derived_expiries(settings.starts_on, date, before)

    liability_effect_total = fn rows ->
      Enum.reduce(rows, 0, fn {_lot_id, kind, amount, _posted_on, _late?}, total ->
        total + Map.fetch!(@credit_liability_effect, kind) * amount
      end)
    end

    opening_liability_cents =
      settings.opening_credit_liability_cents
      |> Kernel.+(liability_effect_total.(before))
      |> Kernel.-(derived.before)

    ordinary_totals = credit_kind_totals(ordinary_on)
    late_totals = credit_kind_totals(late_on)

    # Derived expiry is never an operation and is never late, so it always
    # belongs to the ordinary expired column.
    movements =
      Map.put(ordinary_totals, :expired_cents, ordinary_totals.expired_cents + derived.on)

    closing_liability_cents =
      opening_liability_cents +
        (movements.issued_cents + late_totals.issued_cents) -
        (movements.expired_cents + late_totals.expired_cents) -
        (movements.consumed_cents + late_totals.consumed_cents) -
        (movements.revoked_cents + late_totals.revoked_cents) -
        (movements.absorbed_cents + late_totals.absorbed_cents)

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => stringify_kinds(movements),
      "closing_liability_cents" => closing_liability_cents
    }
  end

  defp late_credit_movements(date) do
    totals =
      date
      |> credit_movements_on(true)
      |> credit_kind_totals()

    Map.new(@credit_kinds, fn kind -> {Atom.to_string(kind), Map.fetch!(totals, kind)} end)
  end

  # Expiry is not an operation: each lot's available balance dies on its own
  # `expires_on`, whether or not any partner operation was submitted then.
  #
  # For every lot expiring between `starts_on` and `date`, that balance is
  # the lot's opening baseline plus its replayed application, restoration,
  # and revocation movements. Only movements posted strictly before the
  # lot's own expiry are replayed: every balance-changing kind is recorded
  # while the lot is unexpired, and a posting forwarded past an expired lot
  # by a later close must not disturb the figure its published day carries.
  #
  # Returns `%{before: ..., on: ...}` — the total expiry falling strictly
  # before `date` (already part of earlier days' closings) and the total
  # falling on `date` itself.
  defp derived_expiries(starts_on, date, before_rows) do
    expiry_by_lot =
      from(l in Lot, where: l.expires_on >= ^starts_on and l.expires_on <= ^date)
      |> select([l], {l.id, l.expires_on})
      |> Repo.all()
      |> Map.new()

    deltas =
      Enum.reduce(before_rows, %{}, fn {lot_id, kind, amount, posted_on, _late?}, acc ->
        case expiry_by_lot do
          %{^lot_id => expires_on} ->
            if Date.compare(posted_on, expires_on) == :lt do
              delta = Map.fetch!(@credit_available_effect, kind) * amount

              if delta == 0 do
                acc
              else
                Map.update(acc, lot_id, delta, &(&1 + delta))
              end
            else
              acc
            end

          _other ->
            acc
        end
      end)

    bases = lot_openings()

    Enum.reduce(expiry_by_lot, %{before: 0, on: 0}, fn {lot_id, expires_on}, totals ->
      available_at_expiry = Map.get(bases, lot_id, 0) + Map.get(deltas, lot_id, 0)
      bucket = if Date.compare(expires_on, date) == :lt, do: :before, else: :on
      Map.update!(totals, bucket, &(&1 + available_at_expiry))
    end)
  end

  defp property_cash_held do
    from(f in Funding,
      join: r in Room,
      on: r.id == f.room_id and r.status == "active",
      join: g in Group,
      on: g.id == f.group_id and g.status == "active",
      where: f.kind == "cash",
      group_by: g.property_id,
      order_by: g.property_id,
      select: {g.property_id, coalesce(sum(f.amount_cents), 0)}
    )
    |> Repo.all()
  end

  defp credit_applied_by_lot do
    from(f in Funding,
      where: f.kind == "credit",
      group_by: f.credit_lot_id,
      select: {f.credit_lot_id, coalesce(sum(f.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp property_openings do
    PropertyOpening
    |> Repo.all()
    |> Map.new(fn opening -> {opening.property_id, opening.cash_held_cents} end)
  end

  defp lot_openings do
    LotOpening
    |> Repo.all()
    |> Map.new(fn opening -> {opening.credit_lot_id, opening.available_cents} end)
  end

  # Kinds come back from the database as text; every stored kind exists as an
  # atom in the effect maps above, so the conversion is total. Rows carry
  # their late flag and (for credit) their posting date, which balance
  # replays, expiry derivation, and the late-adjustment split each consume
  # in their own way.
  defp cash_movements_before(date) do
    cash_movements(date, :lt)
  end

  defp cash_movements_on(date, late?) do
    date |> cash_movements(:eq) |> Enum.filter(&(elem(&1, 3) == late?))
  end

  defp cash_movements(date, comparison) do
    query =
      case comparison do
        :lt -> CashMovement |> where([m], m.posting_date < ^date)
        :eq -> CashMovement |> where([m], m.posting_date == ^date)
      end

    query
    |> order_by([m], m.id)
    |> select([m], {m.property_id, m.kind, m.amount_cents, m.late})
    |> Repo.all()
    |> Enum.map(fn {property_id, kind, amount, late?} ->
      {property_id, String.to_existing_atom(kind), amount, late?}
    end)
  end

  defp credit_movements_before(date) do
    credit_movements(date, :lt)
  end

  defp credit_movements_on(date, late?) do
    date |> credit_movements(:eq) |> Enum.filter(&(elem(&1, 4) == late?))
  end

  defp credit_movements(date, comparison) do
    query =
      case comparison do
        :lt -> CreditMovement |> where([m], m.posting_date < ^date)
        :eq -> CreditMovement |> where([m], m.posting_date == ^date)
      end

    query
    |> order_by([m], m.id)
    |> select([m], {m.credit_lot_id, m.kind, m.amount_cents, m.posting_date, m.late})
    |> Repo.all()
    |> Enum.map(fn {lot_id, kind, amount, posting_date, late?} ->
      {lot_id, String.to_existing_atom(kind), amount, posting_date, late?}
    end)
  end

  defp sum_cash_by_property(movements) do
    Enum.reduce(movements, %{}, fn {property_id, kind, amount, _late?}, acc ->
      Map.update(acc, {property_id, kind}, amount, &(&1 + amount))
    end)
  end

  defp property_ids(sums) do
    sums |> Map.keys() |> Enum.map(fn {property_id, _kind} -> property_id end)
  end

  defp cash_movement_map(sums, property_id) do
    Map.new(@cash_kinds, fn kind -> {kind, Map.get(sums, {property_id, kind}, 0)} end)
  end

  # How the day's ordinary movements move held cash; late movements are
  # added on top by the caller.
  defp held_effect_total(movements) do
    Enum.reduce(movements, 0, fn {kind, amount}, total ->
      total + Map.fetch!(@cash_held_effect, kind) * amount
    end)
  end

  defp credit_kind_totals(rows) do
    # Internal kinds (`applied`, `restored`) move credit between available
    # and applied without any report column of their own.
    Enum.reduce(rows, Map.new(@credit_kinds, fn kind -> {kind, 0} end), fn
      {_lot_id, kind, amount, _posted_on, _late?}, acc
      when kind in @credit_kinds ->
        Map.update!(acc, kind, &(&1 + amount))

      _internal, acc ->
        acc
    end)
  end

  defp stringify_kinds(movements) do
    Map.new(movements, fn {kind, amount} -> {Atom.to_string(kind), amount} end)
  end
end
