defmodule GroupStay.Finance.DailyReport do
  @moduledoc """
  Folds the journal into daily balances, ordinary movements and late adjustments.
  Both movement blocks contribute to balances. Zero-net reclassifications remain
  visible as long as any individual classification is nonzero.
  Summation uses Elixir integers so company totals can exceed SQLite's SUM range.
  """

  @cash_movements ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_movements ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def build(date, entries, status) do
    {credit, cash} = Enum.split_with(entries, &is_nil(&1.property_id))

    cash_accounts =
      cash
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property_id, entries} ->
        {account, late} =
          account(entries, date, :opening_held_cents, :closing_held_cents, @cash_movements)

        {Map.put(account, :property_id, property_id),
         %{property_id: property_id, movements: late}}
      end)

    cash =
      for {account, late} <- cash_accounts,
          account.opening_held_cents != 0 or account.closing_held_cents != 0 or
            not zero_movements?(account.movements) or not zero_movements?(late.movements),
          do: account

    late_cash =
      for {_account, late} <- cash_accounts, not zero_movements?(late.movements), do: late

    {credit, late_credit} =
      account(credit, date, :opening_liability_cents, :closing_liability_cents, @credit_movements)

    %{
      date: date,
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp account(entries, date, opening_key, closing_key, classifications) do
    empty = Map.new(classifications, &{&1, 0})

    {opening, movements, late} =
      Enum.reduce(entries, {0, empty, empty}, fn entry, {opening, movements, late} ->
        cond do
          entry.classification == opening_key or Date.compare(entry.posted_on, date) == :lt ->
            {opening + signed_amount(entry.classification, entry.amount_cents), movements, late}

          entry.late_adjustment ->
            {opening, movements, add_movement(late, entry)}

          true ->
            {opening, add_movement(movements, entry), late}
        end
      end)

    closing = opening + balance_change(movements) + balance_change(late)
    {%{opening_key => opening, :movements => movements, closing_key => closing}, late}
  end

  defp add_movement(movements, entry),
    do: Map.update!(movements, entry.classification, &(&1 + entry.amount_cents))

  defp zero_movements?(movements), do: Enum.all?(movements, fn {_kind, amount} -> amount == 0 end)

  defp balance_change(movements),
    do: Enum.sum(Enum.map(movements, fn {kind, amount} -> signed_amount(kind, amount) end))

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
