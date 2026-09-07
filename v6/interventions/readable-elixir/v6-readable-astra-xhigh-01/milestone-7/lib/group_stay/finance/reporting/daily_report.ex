defmodule GroupStay.Finance.Reporting.DailyReport do
  @moduledoc "Builds a daily report by folding immutable movements over the opening position."

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_in ~w(issued_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  def build(position, entries, date, status) do
    cash =
      Map.new(position["cash"], fn {property, amount} -> {property, cash_balance(amount)} end)

    credit = balance(position["credit_liability_cents"], @credit_in ++ @credit_out)

    {cash, credit} =
      Enum.reduce(entries, {cash, credit}, fn entry, {cash, credit} ->
        if is_nil(entry.property_id) do
          {cash, apply_entry(credit, entry, date, @credit_in, @credit_out)}
        else
          balance = Map.get(cash, entry.property_id, cash_balance(0))
          updated = apply_entry(balance, entry, date, @cash_in, @cash_out)

          {Map.put(cash, entry.property_id, updated), credit}
        end
      end)

    %{
      date: date,
      status: status,
      cash:
        cash
        |> Enum.reject(fn {_property, balance} -> empty?(balance) end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {property, balance} ->
          %{
            property_id: property,
            opening_held_cents: balance.opening,
            movements: balance.movements,
            closing_held_cents: balance.closing
          }
        end),
      credit: %{
        opening_liability_cents: credit.opening,
        movements: credit.movements,
        closing_liability_cents: credit.closing
      },
      late_adjustments: %{
        cash:
          cash
          |> Enum.reject(fn {_property, balance} -> zero_movements?(balance.late_movements) end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {property, balance} ->
            %{property_id: property, movements: balance.late_movements}
          end),
        credit: credit.late_movements
      }
    }
  end

  defp cash_balance(amount), do: balance(amount, @cash_in ++ @cash_out)

  defp balance(amount, kinds) do
    movements = Map.new(kinds, &{&1, 0})
    %{opening: amount, closing: amount, movements: movements, late_movements: movements}
  end

  defp apply_entry(balance, entry, date, incoming, outgoing) do
    change = sum(entry.movements, incoming) - sum(entry.movements, outgoing)

    if Date.compare(entry.posted_on, date) == :lt do
      %{balance | opening: balance.opening + change, closing: balance.closing + change}
    else
      classification = if entry.late_adjustment, do: :late_movements, else: :movements

      balance
      |> Map.put(:closing, balance.closing + change)
      |> Map.update!(classification, fn movements ->
        Map.merge(movements, entry.movements, fn _key, a, b -> a + b end)
      end)
    end
  end

  defp sum(movements, kinds), do: Enum.sum(Enum.map(kinds, &Map.get(movements, &1, 0)))

  defp empty?(balance),
    do:
      balance.opening == 0 and balance.closing == 0 and
        zero_movements?(balance.movements) and zero_movements?(balance.late_movements)

  defp zero_movements?(movements), do: Enum.all?(movements, &(elem(&1, 1) == 0))
end
