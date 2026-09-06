defmodule GroupStay.Finance.Report do
  @moduledoc """
  The daily finance report: how one date moved held cash and credit liability.

  A date's opening position is everything the movement log holds before it, and
  its closing position adds the movements posted on it. Reading a report derives
  those sums and changes nothing, so reports can be read in any order, repeatedly,
  and a later submission simply moves the day it posts to.

  Cash is reported per property. Credit is company-wide, and its expiry is the
  one movement nothing records: a lot expires because a date passed, so the
  report takes it as the liability its opening position, its issues and its
  recorded departures leave unexplained.
  """

  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Finance
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditMovement
  alias GroupStay.Repo

  @doc """
  The report for `date`.

  Returns `{:error, :report_not_available}` while reporting has not started and
  for any date before it started.
  """
  def for_date(%Date{} = date) do
    case Finance.reporting() do
      nil -> {:error, :report_not_available}
      %{starts_on: starts_on} -> before_start(date, starts_on)
    end
  end

  defp before_start(date, starts_on) do
    if Date.before?(date, starts_on) do
      {:error, :report_not_available}
    else
      {:ok,
       %{date: Date.to_iso8601(date), status: "open", cash: cash(date), credit: credit(date)}}
    end
  end

  # --- cash held by each property -----------------------------------------

  defp cash(date) do
    opening = cash_sums(from m in CashMovement, where: m.posting_date < ^date)
    posted = cash_sums(from m in CashMovement, where: m.posting_date == ^date)

    (Map.keys(opening) ++ Map.keys(posted))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&property(&1, Map.get(opening, &1, %{}), Map.get(posted, &1, %{})))
    |> Enum.reject(&quiet?/1)
  end

  defp cash_sums(query) do
    Repo.all(
      from m in query,
        group_by: [m.property_id, m.classification],
        select: {m.property_id, m.classification, sum(m.amount_cents)}
    )
    |> Enum.group_by(&elem(&1, 0), fn {_property_id, classification, amount_cents} ->
      {classification, amount_cents}
    end)
    |> Map.new(fn {property_id, sums} -> {property_id, Map.new(sums)} end)
  end

  defp property(property_id, opening, posted) do
    opening_held_cents = held(opening)

    %{
      property_id: property_id,
      opening_held_cents: opening_held_cents,
      movements:
        Map.new(CashMovement.columns(), fn {classification, column} ->
          {column, Map.get(posted, classification, 0)}
        end),
      closing_held_cents: opening_held_cents + held(posted)
    }
  end

  defp held(sums) do
    Enum.sum(for {classification, amount} <- sums, do: CashMovement.sign(classification) * amount)
  end

  # A property that neither held nor moved anything has nothing to reconcile.
  defp quiet?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_column, amount_cents} -> amount_cents == 0 end)
  end

  # --- credit liability across the company --------------------------------

  defp credit(date) do
    expiries = Map.new(Repo.all(from l in Lot, select: {l.id, l.expires_on}))

    opening_positions = credit_positions(from m in CreditMovement, where: m.posting_date < ^date)
    posted_positions = credit_positions(from m in CreditMovement, where: m.posting_date == ^date)

    # A lot's own balance stops being owed on its expiry date; the credit it has
    # applied to a room keeps its liability whatever the lot's expiry says.
    opening = liability(opening_positions, expiries, &(not Date.before?(&1, date)))

    closing =
      liability(merge(opening_positions, posted_positions), expiries, &Date.after?(&1, date))

    movements = credit_movements(date)

    expired_cents =
      opening + movements.issued_cents - movements.consumed_cents - movements.revoked_cents -
        movements.absorbed_cents - closing

    %{
      opening_liability_cents: opening,
      movements: Map.put(movements, :expired_cents, expired_cents),
      closing_liability_cents: closing
    }
  end

  defp credit_positions(query) do
    Repo.all(
      from m in query,
        group_by: m.lot_ref,
        select: {m.lot_ref, sum(m.remaining_delta_cents), sum(m.applied_delta_cents)}
    )
    |> Map.new(fn {lot_ref, remaining, applied} -> {lot_ref, {remaining, applied}} end)
  end

  defp merge(opening, posted) do
    Map.merge(opening, posted, fn _lot_ref, {r1, a1}, {r2, a2} -> {r1 + r2, a1 + a2} end)
  end

  defp liability(positions, expiries, owed?) do
    Enum.sum(
      for {lot_ref, {remaining, applied}} <- positions do
        if owed?.(Map.fetch!(expiries, lot_ref)), do: remaining + applied, else: applied
      end
    )
  end

  defp credit_movements(date) do
    sums =
      Repo.all(
        from m in CreditMovement,
          where: m.posting_date == ^date,
          group_by: m.event,
          select: {m.event, sum(m.amount_cents)}
      )

    Enum.reduce(
      sums,
      %{issued_cents: 0, consumed_cents: 0, revoked_cents: 0, absorbed_cents: 0},
      fn {event, amount_cents}, movements ->
        case CreditMovement.column(event) do
          nil -> movements
          column -> Map.update!(movements, column, &(&1 + amount_cents))
        end
      end
    )
  end
end
