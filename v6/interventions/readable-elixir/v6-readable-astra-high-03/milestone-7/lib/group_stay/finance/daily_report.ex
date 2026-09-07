defmodule GroupStay.Finance.DailyReport do
  @moduledoc """
  Projects immutable journal entries into ordinary and late daily movements.

  Both movement blocks contribute to balances. Properties are retained when any
  classification is nonzero, even if its net effect on held cash is zero.
  The caller supplies a consistent database snapshot of entries and the cutoff.
  """
  import Ecto.Query
  alias GroupStay.Finance.Entry
  alias GroupStay.Repo

  @cash_movements ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                     retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_movements ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @cash_inflows ~w(received_cents transferred_in_cents)

  def build(date, reporting) do
    entries =
      Repo.all(
        from e in Entry,
          where: e.posted_on <= ^date,
          group_by: [
            e.property_id,
            e.kind,
            e.late_adjustment,
            fragment("? < ?", e.posted_on, ^date)
          ],
          select:
            {e.property_id, e.kind, e.late_adjustment, fragment("? < ?", e.posted_on, ^date),
             sum(e.amount_cents)}
      )
      |> Enum.group_by(&elem(&1, 0))

    properties =
      entries
      |> Map.delete(nil)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property, facts} ->
        {property, balances(facts, @cash_movements, @cash_inflows)}
      end)

    cash =
      for {property, balance} <- properties,
          balance.opening != 0 or balance.closing != 0 or
            nonzero?(balance.movements) or nonzero?(balance.late) do
        %{
          property_id: property,
          opening_held_cents: balance.opening,
          movements: balance.movements,
          closing_held_cents: balance.closing
        }
      end

    late_cash =
      for {property, balance} <- properties,
          nonzero?(balance.late),
          do: %{property_id: property, movements: balance.late}

    credit = balances(Map.get(entries, nil, []), @credit_movements, ["issued_cents"])

    closed? = reporting.closed_through && Date.compare(date, reporting.closed_through) != :gt

    %{
      date: date,
      status: if(closed?, do: "closed", else: "open"),
      cash: cash,
      credit: %{
        opening_liability_cents: credit.opening,
        movements: credit.movements,
        closing_liability_cents: credit.closing
      },
      late_adjustments: %{cash: late_cash, credit: credit.late}
    }
  end

  defp balances(facts, kinds, inflows) do
    zero = Map.new(kinds, &{&1, 0})

    balance =
      Enum.reduce(facts, %{opening: 0, movements: zero, late: zero}, fn
        {_, "opening", _, _, amount}, balance ->
          %{balance | opening: balance.opening + amount}

        {_, kind, late?, earlier?, amount}, balance ->
          if earlier? in [true, 1] do
            %{balance | opening: balance.opening + signed(kind, amount, inflows)}
          else
            block = if late?, do: :late, else: :movements
            update_in(balance, [block, kind], &(&1 + amount))
          end
      end)

    closing =
      Enum.reduce([balance.movements, balance.late], balance.opening, fn movements, total ->
        Enum.reduce(movements, total, fn {kind, amount}, total ->
          total + signed(kind, amount, inflows)
        end)
      end)

    Map.put(balance, :closing, closing)
  end

  defp nonzero?(movements), do: Enum.any?(movements, fn {_, amount} -> amount != 0 end)
  defp signed(kind, amount, inflows), do: if(kind in inflows, do: amount, else: -amount)
end
