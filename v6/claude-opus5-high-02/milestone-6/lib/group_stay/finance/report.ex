defmodule GroupStay.Finance.Report do
  @moduledoc """
  One day's finance report, built from the movements standing when it is read.

  A day's opening balance is everything posted before it and its closing balance is that plus what
  posted on it, so consecutive days chain and a report is never stored. Only the credit expiries
  are not recorded as movements: credit left unused through its `expires_on` expires the following
  day whether or not the partner submitted anything, so those are derived here from what each lot
  held on that date.
  """

  import Ecto.Query

  alias GroupStay.Finance.Movement
  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditLot

  @doc """
  The report for one date.
  """
  def build(%Date{} = date) do
    %{
      date: date,
      status: "open",
      cash: cash(date),
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
      Enum.all?(entry.movements, fn {_kind, cents} -> cents == 0 end)
  end

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
  # then. An operation dated before reporting began can post a lot after its expiry has already
  # passed, and credit cannot enter the liability on one day and leave it on an earlier one, so
  # such a lot expires on the day it arrives.
  defp expiry(expires_on, rows) do
    first_posted_on = rows |> Enum.map(& &1.posting_date) |> Enum.min(Date)
    held_through = Enum.max([expires_on, first_posted_on], Date)
    expired_on = Enum.max([Date.add(expires_on, 1), first_posted_on], Date)

    case rows |> Enum.filter(&(Date.compare(&1.posting_date, held_through) != :gt)) |> total() do
      cents when cents > 0 ->
        [%Movement{posting_date: expired_on, kind: "expired", amount_cents: cents}]

      _cents ->
        []
    end
  end

  ## Shared arithmetic

  # Everything posted before the date opens it, everything posted on it is the day's movement, and
  # the two together close it.
  defp balances(rows, date, kinds) do
    {before, on} = Enum.split_with(rows, &(Date.compare(&1.posting_date, date) == :lt))
    on = Enum.filter(on, &(Date.compare(&1.posting_date, date) == :eq))
    opening_cents = balance(before)

    %{
      opening_cents: opening_cents,
      movements: movements(on, kinds),
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
