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

  A date through the latest close is published and reports as closed. Nothing can
  post to it any more, so it reads back the same bytes for good; work that arrives
  for it afterwards lands on the first open day and is reported there as a late
  adjustment beside that day's ordinary movements. Both make up the day, so the
  opening and closing balances count them together.
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
      {:ok, report(date)}
    end
  end

  defp report(date) do
    {cash, late_cash} = cash(date)
    {credit, late_credit} = credit(date)

    %{
      date: Date.to_iso8601(date),
      status: status(date),
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp status(date) do
    case Finance.closed_through() do
      nil -> "open"
      cutoff -> if Date.after?(date, cutoff), do: "open", else: "closed"
    end
  end

  # --- cash held by each property -----------------------------------------

  defp cash(date) do
    opening = cash_sums(from m in CashMovement, where: m.posting_date < ^date)
    posted = cash_sums(posted_on(CashMovement, date, false))
    late = cash_sums(posted_on(CashMovement, date, true))

    entries =
      [opening, posted, late]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(
        &property(&1, Map.get(opening, &1, %{}), Map.get(posted, &1, %{}), Map.get(late, &1, %{}))
      )

    {for({entry, late} <- entries, not quiet?(entry, late), do: entry),
     for({_entry, late} <- entries, not moved_nothing?(late), do: late)}
  end

  defp posted_on(schema, date, late?) do
    from m in schema, where: m.posting_date == ^date, where: m.late == ^late?
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

  # A property's day, as the entry it reports and the late adjustments inside it.
  defp property(property_id, opening, posted, late) do
    opening_held_cents = held(opening)

    entry = %{
      property_id: property_id,
      opening_held_cents: opening_held_cents,
      movements: cash_movements(posted),
      closing_held_cents: opening_held_cents + held(posted) + held(late)
    }

    {entry, %{property_id: property_id, movements: cash_movements(late)}}
  end

  defp cash_movements(sums) do
    Map.new(CashMovement.columns(), fn {classification, column} ->
      {column, Map.get(sums, classification, 0)}
    end)
  end

  defp held(sums) do
    Enum.sum(for {classification, amount} <- sums, do: CashMovement.sign(classification) * amount)
  end

  # A property that neither held nor moved anything has nothing to reconcile, and
  # a late adjustment is still something the day moved.
  defp quiet?(entry, late) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      moved_nothing?(entry) and moved_nothing?(late)
  end

  defp moved_nothing?(%{movements: movements}),
    do: Enum.all?(movements, fn {_column, amount_cents} -> amount_cents == 0 end)

  # --- credit liability across the company --------------------------------

  defp credit(date) do
    expiries = Map.new(Repo.all(from l in Lot, select: {l.id, l.expires_on}))

    opening_positions = credit_positions(from m in CreditMovement, where: m.posting_date < ^date)
    posted_positions = credit_positions(posted_on(CreditMovement, date, false))
    late_positions = credit_positions(posted_on(CreditMovement, date, true))

    # A lot's own balance stops being owed on its expiry date; the credit it has
    # applied to a room keeps its liability whatever the lot's expiry says.
    opening = liability(opening_positions, expiries, &(not Date.before?(&1, date)))
    owed? = &Date.after?(&1, date)

    # The ordinary movements take the day from its opening position to a running
    # position, and the late adjustments take that the rest of the way.
    ordinary_closing =
      liability(opening_positions, expiries, owed?) + liability(posted_positions, expiries, owed?)

    closing = ordinary_closing + liability(late_positions, expiries, owed?)

    movements = credit_movements(date, false, opening, ordinary_closing)
    late = credit_movements(date, true, ordinary_closing, closing)

    {%{
       opening_liability_cents: opening,
       movements: movements,
       closing_liability_cents: closing
     }, late}
  end

  defp credit_positions(query) do
    Repo.all(
      from m in query,
        group_by: m.lot_ref,
        select: {m.lot_ref, sum(m.remaining_delta_cents), sum(m.applied_delta_cents)}
    )
    |> Map.new(fn {lot_ref, remaining, applied} -> {lot_ref, {remaining, applied}} end)
  end

  defp liability(positions, expiries, owed?) do
    Enum.sum(
      for {lot_ref, {remaining, applied}} <- positions do
        if owed?.(Map.fetch!(expiries, lot_ref)), do: remaining + applied, else: applied
      end
    )
  end

  # Expiry is the liability the recorded events leave unexplained between the
  # position these movements started from and the one they left behind.
  defp credit_movements(date, late?, opening, closing) do
    sums =
      Repo.all(
        from m in posted_on(CreditMovement, date, late?),
          group_by: m.event,
          select: {m.event, sum(m.amount_cents)}
      )

    movements =
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

    expired_cents =
      opening + movements.issued_cents - movements.consumed_cents - movements.revoked_cents -
        movements.absorbed_cents - closing

    Map.put(movements, :expired_cents, expired_cents)
  end
end
