defmodule GroupStay.Finance.Report do
  @moduledoc """
  Pure presentation and balance equations for daily finance reports.

  Ordinary and late movements retain their signed classifications separately.
  Both contribute to balances, including when a reversal has zero net effect.
  """

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  def build(inception, entries, date, status) do
    by_property = Enum.group_by(entries, &elem(&1, 0))

    cash_balances =
      (Map.keys(inception.cash) ++ Map.keys(by_property))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property ->
        {opening, movements, late, closing} =
          balances(
            Map.get(inception.cash, property, 0),
            Map.get(by_property, property, []),
            @cash_in,
            @cash_out
          )

        {%{
           property_id: property,
           opening_held_cents: opening,
           movements: movements,
           closing_held_cents: closing
         }, %{property_id: property, movements: late}}
      end)

    cash =
      cash_balances
      |> Enum.reject(fn {row, late} ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          all_zero?(row.movements) and all_zero?(late.movements)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash =
      cash_balances
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&all_zero?(&1.movements))

    {opening, movements, late_credit, closing} =
      balances(
        inception.credit_liability_cents,
        Map.get(by_property, nil, []),
        ["issued_cents"],
        @credit_out
      )

    %{
      date: date,
      status: status,
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: closing
      },
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp balances(inception, entries, inflows, outflows) do
    empty = Map.new(inflows ++ outflows, &{&1, 0})

    {opening, movements, late} =
      Enum.reduce(entries, {inception, empty, empty}, fn
        {_property, category, today?, late?, amount}, {opening, movements, late} ->
          cond do
            not today? ->
              {opening + signed(category, amount, inflows), movements, late}

            late? ->
              {opening, movements, Map.update!(late, category, &(&1 + amount))}

            true ->
              {opening, Map.update!(movements, category, &(&1 + amount)), late}
          end
      end)

    change =
      Enum.sum(
        for {category, amount} <- Map.to_list(movements) ++ Map.to_list(late),
            do: signed(category, amount, inflows)
      )

    {opening, movements, late, opening + change}
  end

  defp all_zero?(movements), do: Enum.all?(movements, fn {_category, amount} -> amount == 0 end)

  defp signed(category, amount, inflows), do: if(category in inflows, do: amount, else: -amount)
end
