defmodule GroupStay.Finance.Report do
  @moduledoc "Pure presentation and balance equations for an open daily report."

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  def build(inception, entries, date) do
    by_property = Enum.group_by(entries, &elem(&1, 0))

    cash =
      (Map.keys(inception.cash) ++ Map.keys(by_property))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property ->
        {opening, movements, closing} =
          balances(
            Map.get(inception.cash, property, 0),
            Map.get(by_property, property, []),
            @cash_in,
            @cash_out
          )

        %{
          property_id: property,
          opening_held_cents: opening,
          movements: movements,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(row.movements, fn {_category, amount} -> amount == 0 end)
      end)

    {opening, movements, closing} =
      balances(
        inception.credit_liability_cents,
        Map.get(by_property, nil, []),
        ["issued_cents"],
        @credit_out
      )

    %{
      date: date,
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(inception, entries, inflows, outflows) do
    empty = Map.new(inflows ++ outflows, &{&1, 0})

    {opening, movements} =
      Enum.reduce(entries, {inception, empty}, fn {_property, category, today?, amount},
                                                  {opening, movements} ->
        if today? do
          {opening, Map.update!(movements, category, &(&1 + amount))}
        else
          {opening + signed(category, amount, inflows), movements}
        end
      end)

    change = Enum.sum(for {category, amount} <- movements, do: signed(category, amount, inflows))
    {opening, movements, opening + change}
  end

  defp signed(category, amount, inflows), do: if(category in inflows, do: amount, else: -amount)
end
