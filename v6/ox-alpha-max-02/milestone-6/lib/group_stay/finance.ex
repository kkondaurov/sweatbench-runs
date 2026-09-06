defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report: how held cash and hotel-credit liability moved,
  relative to the durable reporting inception point created by
  `start_finance_reporting`.

  ## Inception

  The first applied start operation snapshots the financial state immediately
  before it is processed - every operation already committed contributes to
  the opening position on `starts_on`, whatever its own `occurred_on`. Later
  operations contribute movements instead, posted to the later of their
  `occurred_on` and `starts_on`.

  ## Movements

  Movements are recorded by the domain commands inside the same database
  transaction as the operation's other changes, so a rejected operation leaves
  no movement and a durable retry replays its stored result without recording
  anything twice. Cash movements are attributed to the property where the cash
  is held or was settled - after a deposit transfer that is the destination
  property, not the payment's original one. Credit movements name their lot so
  each lot's unused balance can be tracked over time.

  ## Expiry

  Expiry is evaluated lazily everywhere else in the domain, so it is not an
  event any command records. Reports compute it instead: credit unused through
  a lot's `expires_on` expires on the following date, and the report shows
  that expiry even when no partner operation was submitted that day.

  ## Reports

  A daily report shows one date: its opening position (inception plus all
  earlier posting dates), that date's classified movements, and the closing
  position they imply. Reading reports never changes domain state, and the
  movements reconcile with the cumulative ledger totals once reporting has
  started.
  """

  import Ecto.Query, only: [from: 2]

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Finance.{Movement, OpeningCash, OpeningCreditLot, Reporting}

  # How each classification moves the quantity it belongs to. Stored amounts
  # are signed within their classification; these signs turn them into held
  # cash, liability, and lot-balance deltas.
  @cash_held_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  @credit_liability_signs %{
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  # Kinds that track one lot's unused balance; liability-neutral ones included
  # so expiry lands on the right day however much was applied meanwhile.
  @lot_balance_signs %{
    "issued" => 1,
    "restored" => 1,
    "applied" => -1,
    "revoked" => -1
  }

  @cash_kinds Map.keys(@cash_held_signs)
  @credit_kinds Map.keys(@credit_liability_signs)
  @lot_kinds Map.keys(@lot_balance_signs)

  @doc """
  Starts finance reporting on `starts_on`, capturing the current financial
  state as the opening position. Returns `{:error, :invalid_reporting_date}`
  for a missing or unparseable date and `{:error, :reporting_already_started}`
  once reporting exists. Runs inside the caller's transaction.
  """
  def start_reporting(starts_on, operation_id) do
    with {:ok, date} <- reporting_date(starts_on),
         :ok <- ensure_not_started() do
      snapshot_inception!(date, operation_id)
    end
  end

  defp ensure_not_started do
    if Repo.exists?(Reporting), do: {:error, :reporting_already_started}, else: :ok
  end

  # The opening position is read inside the start operation's transaction, so
  # operations applied earlier in the same batch are part of it and operations
  # after it will record movements instead.
  defp snapshot_inception!(date, operation_id) do
    today = Date.utc_today()

    lots =
      Repo.all(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on > ^today,
          select: {l.id, l.remaining_cents, l.expires_on}
      )

    available_total = lots |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    applied_total = applied_active_credit_total()
    held_by_property = held_cash_by_property()

    changeset =
      Reporting.changeset(%Reporting{}, %{
        starts_on: date,
        start_operation_id: operation_id,
        opening_liability_cents: available_total + applied_total,
        opening_applied_credit_cents: applied_total
      })

    case Repo.insert(changeset) do
      {:ok, reporting} ->
        Enum.each(held_by_property, fn {property_id, cents} ->
          Repo.insert!(%OpeningCash{
            reporting_id: reporting.id,
            property_id: property_id,
            opening_held_cents: cents
          })
        end)

        Enum.each(lots, fn {lot_id, remaining, expires_on} ->
          Repo.insert!(%OpeningCreditLot{
            reporting_id: reporting.id,
            credit_lot_id: lot_id,
            remaining_cents: remaining,
            expires_on: expires_on
          })
        end)

        {:ok, %{starts_on: reporting.starts_on}}

      {:error, _changeset} ->
        {:error, :reporting_already_started}
    end
  end

  defp held_cash_by_property do
    from(a in GroupStay.Groups.RoomCashAllocation,
      join: r in GroupStay.Groups.Room,
      on: r.id == a.room_id,
      join: g in GroupStay.Groups.Group,
      on: g.id == a.group_id,
      where: a.disposition == "held" and r.status == "active" and g.status == "active",
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp applied_active_credit_total do
    Repo.one!(
      from a in GroupStay.Groups.RoomCreditApplication,
        join: r in GroupStay.Groups.Room,
        on: r.id == a.room_id,
        join: g in GroupStay.Groups.Group,
        on: g.id == a.group_id,
        where: r.status == "active" and g.status == "active",
        select: coalesce(sum(a.applied_cents), 0)
    )
  end

  @doc """
  Whether the reporting inception point exists.
  """
  def reporting_started?, do: Repo.exists?(Reporting)

  @doc """
  The reporting posting date for an operation with `occurred_on`: the later of
  the operation date and `starts_on`. An unusable `occurred_on` posts at
  `starts_on`; commands that never accepted an operation date keep doing so.
  """
  def posting_date(occurred_on) do
    case to_date(occurred_on) do
      {:ok, date} -> later(date, starts_on())
      :error -> starts_on()
    end
  end

  defp starts_on do
    Repo.one(from(r in Reporting, select: r.starts_on, limit: 1)) || Date.utc_today()
  end

  defp later(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  @doc """
  Records movement rows at `posting_date`. Does nothing before reporting has
  started or when there is nothing to record; otherwise inserts every row in
  the caller's transaction.

  Each row is `%{kind:, property_id:, credit_lot_id:, amount_cents:}`.
  """
  def record_movements!(_posting_date, []), do: :ok

  def record_movements!(posting_date, rows) do
    if reporting_started?() do
      rows
      |> Enum.reject(fn row -> row.amount_cents == 0 end)
      |> Enum.each(fn row ->
        Repo.insert!(%Movement{
          posting_date: posting_date,
          kind: row.kind,
          property_id: row.property_id,
          credit_lot_id: row.credit_lot_id,
          amount_cents: row.amount_cents
        })
      end)
    end

    :ok
  end

  @doc """
  The daily finance report for `date`, or
  `{:error, :report_not_available}` before reporting has started or for a
  date before `starts_on`.
  """
  def daily_report(date) do
    case Repo.one(Reporting) do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_daily_report(reporting, date)}
        end
    end
  end

  defp build_daily_report(reporting, date) do
    day_rows = Repo.all(from(m in Movement, where: m.posting_date == ^date))
    prior_rows = Repo.all(from(m in Movement, where: m.posting_date < ^date))
    expiries = computed_expiries(reporting, date)

    %{
      date: date,
      status: "open",
      cash: build_cash_section(reporting, date, day_rows, prior_rows),
      credit: build_credit_section(reporting, day_rows, prior_rows, expiries)
    }
  end

  defp build_cash_section(reporting, _date, day_rows, prior_rows) do
    inception_opening =
      from(o in OpeningCash,
        where: o.reporting_id == ^reporting.id,
        select: {o.property_id, o.opening_held_cents}
      )
      |> Repo.all()
      |> Map.new()

    prior_deltas = sum_cash_deltas(prior_rows)
    day_amounts = sum_cash_day_kinds(day_rows)

    properties =
      [inception_opening, prior_deltas, day_amounts]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property ->
      opening = Map.get(inception_opening, property, 0) + Map.get(prior_deltas, property, 0)
      cash_entry(property, opening, Map.get(day_amounts, property, %{}))
    end)
  end

  # Report-facing movement keys carry the _cents suffix; the balance-tracking
  # kinds never surface.
  defp movement_key(kind), do: "#{kind}_cents"

  defp report_kind(key), do: String.replace_suffix(key, "_cents", "")

  defp cash_entry(property, opening, day_kinds) do
    movements =
      Map.new(@cash_kinds, fn kind -> {movement_key(kind), Map.get(day_kinds, kind, 0)} end)

    closing =
      movements
      |> Enum.map(fn {key, amount} -> amount * @cash_held_signs[report_kind(key)] end)
      |> Enum.sum()
      |> Kernel.+(opening)

    if opening == 0 and closing == 0 and movements |> Map.values() |> Enum.all?(&(&1 == 0)) do
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
  end

  defp build_credit_section(reporting, day_rows, prior_rows, expiries) do
    prior_delta =
      sum_credit_signed(prior_rows) +
        Enum.sum(Enum.map(expiries.prior, &(-&1.amount_cents)))

    opening = reporting.opening_liability_cents + prior_delta

    day_movements =
      day_rows
      |> Enum.filter(&credit_row?/1)
      |> Enum.map(fn row -> {movement_key(row.kind), row.amount_cents} end)
      |> Kernel.++(
        Enum.map(expiries.day, fn expiry -> {movement_key("expired"), expiry.amount_cents} end)
      )
      |> Enum.reduce(Map.new(@credit_kinds, &{movement_key(&1), 0}), fn {key, amount}, acc ->
        Map.update!(acc, key, &(&1 + amount))
      end)

    closing =
      day_movements
      |> Enum.map(fn {key, amount} ->
        amount * @credit_liability_signs[report_kind(key)]
      end)
      |> Enum.sum()
      |> Kernel.+(opening)

    %{
      opening_liability_cents: opening,
      movements: day_movements,
      closing_liability_cents: closing
    }
  end

  # Credit that remains unused through its expires_on date expires on the
  # following date. Each candidate lot's unused balance is replayed from its
  # inception snapshot plus its recorded balance movements up to the expiry
  # date. Lots whose expiry falls before reporting began surface pinned to
  # starts_on, the earliest date any report can show them.
  defp computed_expiries(reporting, date) do
    horizon = Date.add(date, -1)

    candidates =
      Repo.all(
        from l in CreditLot,
          where: l.expires_on <= ^horizon,
          select: {l.id, l.expires_on}
      )

    Enum.reduce(candidates, %{day: [], prior: []}, fn {lot_id, expires_on}, acc ->
      pin = expiry_pin(reporting, expires_on)

      cond do
        Date.compare(pin, date) == :gt ->
          acc

        true ->
          pool = lot_pool(lot_id, expires_on)

          if pool == 0 do
            acc
          else
            bucket = if Date.compare(pin, date) == :eq, do: :day, else: :prior

            Map.update!(acc, bucket, &[%{amount_cents: pool} | &1])
          end
      end
    end)
  end

  # The balance of a lot that has not already expired as of `as_of`: its
  # replayed unused pool minus whatever an earlier expiry removed. Revocations
  # use this so a chargeback cannot report taking liability that expiry already
  # took from an unused remainder.
  def live_lot_balance(lot_id, as_of) do
    expires_on = Repo.one!(from(l in CreditLot, where: l.id == ^lot_id, select: l.expires_on))
    pool_after = lot_pool(lot_id, as_of)

    expired_already =
      if Date.compare(expiry_pin(%Reporting{starts_on: starts_on()}, expires_on), as_of) != :gt,
        do: lot_pool(lot_id, expires_on),
        else: 0

    max(0, pool_after - expired_already)
  end

  defp expiry_pin(reporting, expires_on),
    do: later(Date.add(expires_on, 1), reporting.starts_on)

  # One lot's unused pool as of a date: its inception snapshot plus every
  # recorded balance movement up to that date, never below zero.
  defp lot_pool(lot_id, as_of) do
    base =
      Repo.one(
        from(o in OpeningCreditLot,
          where: o.credit_lot_id == ^lot_id,
          select: coalesce(sum(o.remaining_cents), 0)
        )
      )

    deltas =
      from(m in Movement,
        where: m.credit_lot_id == ^lot_id and m.kind in ^@lot_kinds and m.posting_date <= ^as_of,
        select: {m.kind, m.amount_cents}
      )
      |> Repo.all()
      |> Enum.map(fn {kind, amount} -> @lot_balance_signs[kind] * amount end)
      |> Enum.sum()

    max(0, base + deltas)
  end

  defp credit_row?(row), do: Map.has_key?(@credit_liability_signs, row.kind)

  # Prior-date rows collapse into one signed held-cash delta per property.
  defp sum_cash_deltas(rows) do
    rows
    |> Enum.filter(&is_map_key(@cash_held_signs, &1.kind))
    |> Enum.reduce(%{}, fn row, acc ->
      delta = @cash_held_signs[row.kind] * row.amount_cents

      if delta == 0 do
        acc
      else
        Map.update(acc, row.property_id, delta, &(&1 + delta))
      end
    end)
  end

  # Day rows keep their classification: signed amount per property per kind.
  defp sum_cash_day_kinds(rows) do
    rows
    |> Enum.filter(&is_map_key(@cash_held_signs, &1.kind))
    |> Enum.group_by(& &1.property_id, fn row -> {row.kind, row.amount_cents} end)
    |> Map.new(fn {property, pairs} ->
      {property,
       Enum.reduce(pairs, %{}, fn {kind, amount}, acc ->
         Map.update(acc, kind, amount, &(&1 + amount))
       end)}
    end)
  end

  defp sum_credit_signed(rows) do
    rows
    |> Enum.filter(&credit_row?/1)
    |> Enum.map(fn row -> @credit_liability_signs[row.kind] * row.amount_cents end)
    |> Enum.sum()
  end

  defp reporting_date(value) do
    case to_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, :invalid_reporting_date}
    end
  end

  defp to_date(%Date{} = date), do: {:ok, date}

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp to_date(_value), do: :error
end
