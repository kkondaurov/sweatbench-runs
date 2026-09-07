defmodule GroupStay.Finance.DailyReport do
  @moduledoc """
  Folds the journal into daily opening balances, net movements and closing balances.
  Summation uses Elixir integers so company totals can exceed SQLite's SUM range.
  """

  @cash_movements ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_movements ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def build(date, entries) do
    {credit, cash} = Enum.split_with(entries, &is_nil(&1.property_id))

    cash =
      cash
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property_id, entries} ->
        entries
        |> account(date, :opening_held_cents, :closing_held_cents, @cash_movements)
        |> Map.put(:property_id, property_id)
      end)
      |> Enum.reject(fn account ->
        account.opening_held_cents == 0 and account.closing_held_cents == 0 and
          Enum.all?(account.movements, fn {_classification, amount} -> amount == 0 end)
      end)

    %{
      date: date,
      status: "open",
      cash: cash,
      credit:
        account(
          credit,
          date,
          :opening_liability_cents,
          :closing_liability_cents,
          @credit_movements
        )
    }
  end

  defp account(entries, date, opening_key, closing_key, classifications) do
    initial = {0, Map.new(classifications, &{&1, 0})}

    {opening, movements} =
      Enum.reduce(entries, initial, fn entry, {opening, movements} ->
        if entry.classification == opening_key or Date.compare(entry.posted_on, date) == :lt do
          {opening + signed_amount(entry.classification, entry.amount_cents), movements}
        else
          {opening, Map.update!(movements, entry.classification, &(&1 + entry.amount_cents))}
        end
      end)

    change = Enum.sum(Enum.map(movements, fn {kind, amount} -> signed_amount(kind, amount) end))
    %{opening_key => opening, :movements => movements, closing_key => opening + change}
  end

  defp signed_amount(kind, amount)
       when kind in [
              :opening_held_cents,
              :opening_liability_cents,
              :received_cents,
              :transferred_in_cents,
              :issued_cents
            ],
       do: amount

  defp signed_amount(_kind, amount), do: -amount
end
