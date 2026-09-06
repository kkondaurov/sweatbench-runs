defmodule GroupStay.Finance do
  @moduledoc """
  The durable reporting inception point and the daily finance report.

  `start_reporting/1` captures the financial state immediately before the
  first applied start operation — cash held per property and each credit
  lot's available balance — as the opening position on `starts_on`. Every
  applied operation processed after that point posts its finance effects as
  signed movement rows at its reporting posting date, the later of its
  `occurred_on` and `starts_on`. Operations processed before the start post
  nothing: their effects are already inside the opening position.

  A day's report is a pure aggregation of the opening position plus the
  movements posted up to and on that day. Reading reports never changes
  state, reading in any order yields the same numbers, and a later submission
  revises an earlier open day simply by appending rows at its posting date.

  Expiry is never an operation, so each lot's expiry movement is derived for
  any date from the lot's opening baseline and its recorded application,
  restoration, and revocation movements posted before `expires_on` — which
  lets the report show expiry even when no partner operation was submitted
  that day.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditMovement
  alias GroupStay.Finance.LotOpening
  alias GroupStay.Finance.PropertyOpening
  alias GroupStay.Finance.ReportingSettings
  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  # Movement kinds are stored exactly as the daily-report columns name them.
  @cash_kinds ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

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
  The reporting posting date for an operation with the given `occurred_on`:
  the later of that date and `starts_on`, or `nil` for operations processed
  before reporting started (which post no movements at all).
  """
  def posting_date(%Date{} = occurred_on) do
    case settings() do
      nil ->
        nil

      %{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  @doc """
  Appends one signed cash movement for the property, or does nothing when
  `posting_date` is nil (reporting had not started).
  """
  def record_cash(posting_date, property_id, kind, amount_cents)

  def record_cash(nil, _property_id, _kind, _amount_cents), do: :ok

  def record_cash(%Date{} = posting_date, property_id, kind, amount_cents) do
    if amount_cents == 0 do
      :ok
    else
      Repo.insert!(%CashMovement{
        posting_date: posting_date,
        property_id: property_id,
        kind: Atom.to_string(kind),
        amount_cents: amount_cents
      })

      :ok
    end
  end

  @doc """
  Appends one signed hotel-credit movement against the lot, or does nothing
  when `posting_date` is nil.
  """
  def record_credit(posting_date, credit_lot_id, kind, amount_cents)

  def record_credit(nil, _credit_lot_id, _kind, _amount_cents), do: :ok

  def record_credit(%Date{} = posting_date, credit_lot_id, kind, amount_cents) do
    if amount_cents == 0 do
      :ok
    else
      Repo.insert!(%CreditMovement{
        posting_date: posting_date,
        credit_lot_id: credit_lot_id,
        kind: Atom.to_string(kind),
        amount_cents: amount_cents
      })

      :ok
    end
  end

  @doc """
  The daily report for `date`, or `{:error, :report_not_available}` before
  reporting has started or for a date before `starts_on`.
  """
  @spec daily_report(Date.t()) :: {:ok, map()} | report_error()
  def daily_report(%Date{} = date) do
    case settings() do
      nil ->
        {:error, :report_not_available}

      settings ->
        if Date.compare(date, settings.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(date, settings)}
        end
    end
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
      "credit" => credit_section(date, settings)
    }
  end

  defp cash_section(date) do
    openings = property_openings()

    opening =
      cash_movements_before(date)
      |> Enum.reduce(openings, fn {property_id, kind, amount}, acc ->
        delta = Map.fetch!(@cash_held_effect, kind) * amount
        Map.update(acc, property_id, delta, &(&1 + delta))
      end)

    movements_on_date = cash_movements_on(date)

    sums =
      Enum.reduce(movements_on_date, %{}, fn {property_id, kind, amount}, acc ->
        Map.update(acc, {property_id, kind}, amount, &(&1 + amount))
      end)

    properties =
      [Map.keys(opening), Enum.map(movements_on_date, fn {property_id, _, _} -> property_id end)]
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening_held_cents = Map.get(opening, property_id, 0)

      movements =
        Map.new(@cash_kinds, fn kind -> {kind, Map.get(sums, {property_id, kind}, 0)} end)

      closing_held_cents =
        Enum.reduce(movements, opening_held_cents, fn {kind, amount}, total ->
          total + Map.fetch!(@cash_held_effect, kind) * amount
        end)

      any_movement? = Enum.any?(Map.values(movements), &(&1 != 0))

      if opening_held_cents != 0 or closing_held_cents != 0 or any_movement? do
        [
          %{
            "property_id" => property_id,
            "opening_held_cents" => opening_held_cents,
            "movements" =>
              Map.new(movements, fn {kind, amount} -> {Atom.to_string(kind), amount} end),
            "closing_held_cents" => closing_held_cents
          }
        ]
      else
        []
      end
    end)
  end

  defp credit_section(date, settings) do
    movements_before = credit_movements_before(date)
    movements_on_date = credit_movements_on(date)

    sum_for_kind = fn kind ->
      Enum.reduce(movements_on_date, 0, fn {_lot_id, movement_kind, amount}, total ->
        if movement_kind == kind, do: total + amount, else: total
      end)
    end

    derived = derived_expiries(settings.starts_on, date, movements_before)

    opening_liability_cents =
      movements_before
      |> Enum.reduce(settings.opening_credit_liability_cents, fn {_lot_id, kind, amount}, total ->
        total + Map.fetch!(@credit_liability_effect, kind) * amount
      end)
      |> Kernel.-(derived.before)

    movements = %{
      issued_cents: sum_for_kind.(:issued_cents),
      expired_cents: sum_for_kind.(:expired_cents) + derived.on,
      consumed_cents: sum_for_kind.(:consumed_cents),
      revoked_cents: sum_for_kind.(:revoked_cents),
      absorbed_cents: sum_for_kind.(:absorbed_cents)
    }

    closing_liability_cents =
      opening_liability_cents + movements.issued_cents - movements.expired_cents -
        movements.consumed_cents - movements.revoked_cents - movements.absorbed_cents

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => Map.new(movements, fn {kind, amount} -> {Atom.to_string(kind), amount} end),
      "closing_liability_cents" => closing_liability_cents
    }
  end

  # Expiry is not an operation: each lot's available balance dies on its own
  # `expires_on`, whether or not any partner operation was submitted then.
  #
  # For every lot expiring between `starts_on` and `date`, that balance is
  # the lot's opening baseline plus its replayed application, restoration,
  # and revocation movements. Every movement kind that changes a lot's
  # available balance is recorded only while the lot is unexpired, so all of
  # them precede the lot's expiry and summing the movements posted before
  # `date` yields each lot's balance at its own expiry exactly.
  #
  # Returns `%{before: ..., on: ...}` — the total expiry falling strictly
  # before `date` (already part of earlier days' closings) and the total
  # falling on `date` itself.
  defp derived_expiries(starts_on, date, movements_before) do
    deltas =
      movements_before
      |> Enum.reduce(%{}, fn {lot_id, kind, amount}, acc ->
        delta = Map.fetch!(@credit_available_effect, kind) * amount

        if delta == 0 do
          acc
        else
          Map.update(acc, lot_id, delta, &(&1 + delta))
        end
      end)

    bases = lot_openings()

    from(l in Lot, where: l.expires_on >= ^starts_on and l.expires_on <= ^date)
    |> select([l], {l.id, l.expires_on})
    |> Repo.all()
    |> Enum.reduce(%{before: 0, on: 0}, fn {lot_id, expires_on}, totals ->
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
  # atom in the effect maps above, so the conversion is total.
  defp cash_movements_before(date) do
    cash_movements(date, :lt)
  end

  defp cash_movements_on(date) do
    cash_movements(date, :eq)
  end

  defp cash_movements(date, comparison) do
    query =
      case comparison do
        :lt -> CashMovement |> where([m], m.posting_date < ^date)
        :eq -> CashMovement |> where([m], m.posting_date == ^date)
      end

    query
    |> order_by([m], m.id)
    |> select([m], {m.property_id, m.kind, m.amount_cents})
    |> Repo.all()
    |> Enum.map(fn {property_id, kind, amount} ->
      {property_id, String.to_existing_atom(kind), amount}
    end)
  end

  defp credit_movements_before(date) do
    credit_movements(date, :lt)
  end

  defp credit_movements_on(date) do
    credit_movements(date, :eq)
  end

  defp credit_movements(date, comparison) do
    query =
      case comparison do
        :lt -> CreditMovement |> where([m], m.posting_date < ^date)
        :eq -> CreditMovement |> where([m], m.posting_date == ^date)
      end

    query
    |> order_by([m], m.id)
    |> select([m], {m.credit_lot_id, m.kind, m.amount_cents})
    |> Repo.all()
    |> Enum.map(fn {lot_id, kind, amount} ->
      {lot_id, String.to_existing_atom(kind), amount}
    end)
  end
end
