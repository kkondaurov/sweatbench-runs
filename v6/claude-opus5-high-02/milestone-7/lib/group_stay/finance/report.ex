defmodule GroupStay.Finance.Report do
  @moduledoc """
  One day's finance report, built from the movements standing when it is read.

  A day's opening balance is everything posted before it and its closing balance is that plus what
  posted on it, so consecutive days chain and a report is never stored. A day a close has
  published is stable because nothing can post into it any more: an operation processed after a
  close posts on the first open day.

  Movements a close pushed forward are stated apart from the day's ordinary movements, so a
  controller can see which of the day's figures belong to it and which are corrections to a period
  already signed off. Both count towards the day's balances.

  Only the credit expiries are not recorded as movements: credit left unused through its
  `expires_on` expires the following day whether or not the partner submitted anything, so those
  are derived here from what each lot held on that date.
  """

  import Ecto.Query

  alias GroupStay.Finance.Movement
  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditLot

  @doc """
  The report for one date.
  """
  def build(%Date{} = date, status) do
    cash = cash(date)

    %{
      date: date,
      status: status,
      cash: cash,
      # A property is only worth naming among the late adjustments when it has one.
      late_cash: Enum.reject(cash, &still?(&1.late_movements)),
      credit: credit(date)
    }
  end

  ## Held cash, property by property

  defp cash(date) do
    Movement.cash()
    |> scoped()
    |> Enum.group_by(& &1.property_id)
    |> Enum.map(fn {property_id, rows} ->
      rows |> balances(date, Movement.cash_kinds()) |> Map.put(:property_id, property_id)
    end)
    # A property with nothing to say on the day is left out of the report entirely.
    |> Enum.reject(&quiet?/1)
    |> Enum.sort_by(& &1.property_id)
  end

  defp quiet?(entry) do
    entry.opening_cents == 0 and entry.closing_cents == 0 and
      still?(entry.movements) and still?(entry.late_movements)
  end

  # A classification that nets to zero against another still says something, so every column has
  # to be zero before a block of movements is left out.
  defp still?(movements), do: Enum.all?(movements, fn {_kind, cents} -> cents == 0 end)

  ## Hotel-credit liability, company-wide

  defp credit(date) do
    (scoped(Movement.credit()) ++ expiries())
    |> balances(date, Movement.credit_kinds())
  end

  # Credit that is still sitting in a lot when its expiry date passes expires the next day. The
  # amount is what the lot held on that date, which is what the report has posted to it by then.
  defp expiries do
    expiry_dates = Repo.all(from l in CreditLot, select: {l.id, l.expires_on}) |> Map.new()

    Movement.lot()
    |> scoped()
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.flat_map(fn {lot_id, rows} -> expiry(Map.fetch!(expiry_dates, lot_id), rows) end)
  end

  # A lot expires the day after its expiry date, holding whatever the report has posted to it by
  # then. Credit can also reach a lot after that day has passed - the operation returning it was
  # dated before reporting began, or a close pushed it into the open period - and credit cannot
  # leave the liability before it enters it, so such an amount expires on the day it arrives.
  defp expiry(expires_on, rows) do
    posted = Enum.group_by(rows, & &1.posting_date)
    expired_on = Date.add(expires_on, 1)

    {expiries, _held} =
      posted
      |> checkpoints(expired_on)
      |> Enum.flat_map_reduce({0, 0}, fn date, held ->
        held = hold(held, Map.get(posted, date, []), expired_on)

        if Date.compare(date, expires_on) == :gt, do: expire(date, held), else: {[], held}
      end)

    expiries
  end

  # The lot is looked at on every day something reaches it, and on the day it expires. A lot the
  # report only hears from after that day expires the first time it is heard from.
  defp checkpoints(posted, expired_on) do
    dates = Map.keys(posted)

    [Enum.max([expired_on, Enum.min(dates, Date)], Date) | dates]
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  # An amount is only a late adjustment to the expiry when a close moved the day it expires on.
  # Anything reaching the lot by the day it expires expires on that day whenever it was posted.
  defp hold({ordinary_cents, late_cents}, rows, expired_on) do
    Enum.reduce(rows, {ordinary_cents, late_cents}, fn row, {ordinary, late} ->
      if row.late and Date.compare(row.posting_date, expired_on) == :gt do
        {ordinary, late + row.amount_cents}
      else
        {ordinary + row.amount_cents, late}
      end
    end)
  end

  defp expire(date, {ordinary_cents, late_cents}) do
    expired =
      for {cents, late} <- [{ordinary_cents, false}, {late_cents, true}], cents > 0 do
        %Movement{posting_date: date, kind: "expired", amount_cents: cents, late: late}
      end

    {expired, {min(ordinary_cents, 0), min(late_cents, 0)}}
  end

  ## Shared arithmetic

  # Everything posted before the date opens it, everything posted on it is the day's movement, and
  # the two together close it. What a close pushed onto the day is a movement of the day like any
  # other; the report simply states it separately.
  defp balances(rows, date, kinds) do
    {before, on} = Enum.split_with(rows, &(Date.compare(&1.posting_date, date) == :lt))
    on = Enum.filter(on, &(Date.compare(&1.posting_date, date) == :eq))
    {late, ordinary} = Enum.split_with(on, & &1.late)
    opening_cents = balance(before)

    %{
      opening_cents: opening_cents,
      movements: movements(ordinary, kinds),
      late_movements: movements(late, kinds),
      closing_cents: opening_cents + balance(on)
    }
  end

  defp movements(rows, kinds) do
    by_kind = Enum.group_by(rows, & &1.kind)

    for kind <- kinds, into: %{}, do: {kind, by_kind |> Map.get(kind, []) |> total()}
  end

  defp balance(rows), do: Enum.sum(Enum.map(rows, &Movement.balance_cents/1))

  defp total(rows), do: Enum.sum(Enum.map(rows, & &1.amount_cents))

  defp scoped(scope), do: Repo.all(from m in Movement, where: m.scope == ^scope)
end
