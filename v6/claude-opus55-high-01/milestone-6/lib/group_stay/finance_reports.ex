defmodule GroupStay.FinanceReports do
  @moduledoc """
  Daily finance reports: how cash held for each property and the company-wide hotel-credit
  liability moved on one date.

  Reporting starts with a `start_finance_reporting` operation, which records the financial state
  immediately before it as the opening position on `starts_on`. Every operation applied after
  that records its finance effects as `GroupStay.FinanceReports.Posting`s in its own transaction,
  all on one posting date: the later of its `occurred_on` and `starts_on`. A report sums the
  postings, so a later submission dated earlier changes that earlier report. Reading a report
  never writes.

  Unapplied credit expires with its lot, without an operation. Each lot's unapplied balance is
  therefore posted as it changes before the lot's `expires_on`, and whatever it amounts to is
  reported as expired on that date. A balance change posted on or after that date concerns credit
  the reports already show as expired, so it is reported as an expiry movement at once.

  Postings are written by `GroupStay.PartnerOperations`.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.FinanceReports.{Posting, ReportingStart}
  alias GroupStay.Groups.{CashAllocation, Group}
  alias GroupStay.Repo

  @cash_movements ~w(received transferred_in transferred_out refunded retained
                     converted_to_credit reduced charged_back)
  # Movements that increase held cash; the others decrease it.
  @cash_inflows ~w(received transferred_in)

  @credit_movements ~w(issued expired consumed revoked absorbed)
  # Movements that increase the liability; the others decrease it.
  @credit_inflows ~w(issued)

  @lot_kinds ~w(opening_lot_balance lot_balance)

  @doc "The start of reporting, or `nil` before reporting has started."
  def reporting_start, do: Repo.one(from s in ReportingStart, limit: 1)

  @doc """
  The posting date for an operation that occurred on `occurred_on`, or `nil` before reporting
  has started.
  """
  def posting_date(nil = _occurred_on), do: nil

  def posting_date(%Date{} = occurred_on) do
    case reporting_start() do
      nil -> nil
      %ReportingStart{starts_on: starts_on} -> Enum.max([occurred_on, starts_on], Date)
    end
  end

  @doc """
  Starts reporting on `starts_on`, recording the current financial state as its opening position:
  cash held by each property, the credit liability, and the unapplied balance of every lot that
  has not expired before `starts_on`.
  """
  def start!(%Date{} = starts_on, operation_id) do
    Repo.insert!(%ReportingStart{starts_on: starts_on, operation_id: operation_id})
    opening = %{operation_id: operation_id, posting_on: starts_on}

    from(a in CashAllocation,
      join: g in Group,
      on: g.id == a.group_ref,
      where: a.status == "held",
      group_by: g.property_id,
      select: {g.property_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, cents} ->
      insert!(opening, "opening_held", cents, property_id: property_id)
    end)

    lots =
      Repo.all(
        from l in CreditLot,
          where: l.expires_on >= ^starts_on and l.remaining_cents > 0,
          select: {l.id, l.remaining_cents}
      )

    for {lot_ref, cents} <- lots,
        do: insert!(opening, "opening_lot_balance", cents, lot_ref: lot_ref)

    applied =
      Repo.one(
        from a in CreditApplication, where: a.status == "applied", select: sum(a.amount_cents)
      )

    liability = (applied || 0) + (lots |> Enum.map(&elem(&1, 1)) |> Enum.sum())
    insert!(opening, "opening_liability", liability)
  end

  @doc "Posts a movement of held cash for `property_id`."
  def post_cash!(cmd, property_id, kind, cents) when kind in @cash_movements,
    do: insert!(cmd, kind, cents, property_id: property_id)

  @doc "Posts a movement of the credit liability."
  def post_credit!(cmd, kind, cents) when kind in @credit_movements, do: insert!(cmd, kind, cents)

  @doc """
  Posts a change of `delta` to a lot's unapplied balance. `cause` is the credit movement it
  represents, `issued` or `revoked`, or `nil` when credit moves between the lot and a group's
  deposit, which does not change the liability.
  """
  def post_lot_balance!(cmd, lot, delta, cause)

  def post_lot_balance!(%{posting_on: nil}, _lot, _delta, _cause), do: :ok

  def post_lot_balance!(cmd, %CreditLot{} = lot, delta, cause)
      when cause in [nil, "issued", "revoked"] do
    cond do
      Date.before?(cmd.posting_on, lot.expires_on) ->
        insert!(cmd, "lot_balance", delta, lot_ref: lot.id)
        if cause, do: post_credit!(cmd, cause, liability_effect(cause, delta))

      # Revoking credit that has already expired leaves the liability as it is.
      cause == "revoked" ->
        :ok

      true ->
        if cause, do: post_credit!(cmd, cause, liability_effect(cause, delta))
        post_credit!(cmd, "expired", delta)
    end
  end

  defp liability_effect(kind, delta) when kind in @credit_inflows, do: delta
  defp liability_effect(_kind, delta), do: -delta

  # Nothing is posted before reporting starts, and a zero amount is not a movement.
  defp insert!(cmd, kind, cents, refs \\ [])
  defp insert!(%{posting_on: nil}, _kind, _cents, _refs), do: :ok
  defp insert!(_cmd, _kind, 0 = _cents, _refs), do: :ok

  defp insert!(%{posting_on: %Date{} = on, operation_id: operation_id}, kind, cents, refs) do
    Repo.insert!(
      struct!(
        %Posting{operation_id: operation_id, posting_date: on, kind: kind, amount_cents: cents},
        refs
      )
    )

    :ok
  end

  ## Reports

  @doc """
  The report for `date`. Returns `{:error, :not_available}` before reporting has started or for
  a date before `starts_on`.
  """
  def daily_report(%Date{} = date) do
    case reporting_start() do
      %ReportingStart{starts_on: starts_on} ->
        if Date.before?(date, starts_on),
          do: {:error, :not_available},
          else: {:ok, report(date)}

      nil ->
        {:error, :not_available}
    end
  end

  defp report(date) do
    before = sums(from p in Posting, where: p.posting_date < ^date)
    on_date = sums(from p in Posting, where: p.posting_date == ^date)

    %{
      date: date,
      status: "open",
      cash: cash(before, on_date),
      credit: credit(before, on_date, date)
    }
  end

  # Amounts by `{property_id, kind}`.
  defp sums(query) do
    from(p in query,
      where: p.kind not in @lot_kinds,
      group_by: [p.property_id, p.kind],
      select: {{p.property_id, p.kind}, sum(p.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cash(before, on_date) do
    properties =
      for {{property_id, _kind}, _cents} <- Map.merge(before, on_date),
          property_id != nil,
          uniq: true,
          do: property_id

    properties
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      amount = fn sums, kind -> Map.get(sums, {property_id, kind}, 0) end
      opening = amount.(before, "opening_held") + amount.(on_date, "opening_held")
      opening = opening + net(@cash_movements, @cash_inflows, &amount.(before, &1))
      movements = Map.new(@cash_movements, &{"#{&1}_cents", amount.(on_date, &1)})

      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: movements,
        closing_held_cents: opening + net(@cash_movements, @cash_inflows, &amount.(on_date, &1))
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(Map.values(entry.movements), &(&1 == 0))
    end)
  end

  defp credit(before, on_date, date) do
    {expired_before, expired_on_date} = lot_expiries(date)

    amount = fn sums, kind -> Map.get(sums, {nil, kind}, 0) end
    before = Map.update(before, {nil, "expired"}, expired_before, &(&1 + expired_before))
    on_date = Map.update(on_date, {nil, "expired"}, expired_on_date, &(&1 + expired_on_date))

    opening = amount.(before, "opening_liability") + amount.(on_date, "opening_liability")
    opening = opening + net(@credit_movements, @credit_inflows, &amount.(before, &1))

    %{
      opening_liability_cents: opening,
      movements: Map.new(@credit_movements, &{"#{&1}_cents", amount.(on_date, &1)}),
      closing_liability_cents:
        opening + net(@credit_movements, @credit_inflows, &amount.(on_date, &1))
    }
  end

  # Unapplied lot balances that expired before `date` and on `date`. Only changes dated before a
  # lot's expiry are posted as its balance.
  defp lot_expiries(date) do
    expiring =
      from p in Posting,
        join: l in CreditLot,
        on: l.id == p.lot_ref,
        where: p.kind in @lot_kinds,
        select: coalesce(sum(p.amount_cents), 0)

    {Repo.one(where(expiring, [_p, l], l.expires_on < ^date)),
     Repo.one(where(expiring, [_p, l], l.expires_on == ^date))}
  end

  defp net(kinds, inflows, amount) do
    kinds
    |> Enum.map(fn kind -> if kind in inflows, do: amount.(kind), else: -amount.(kind) end)
    |> Enum.sum()
  end
end
