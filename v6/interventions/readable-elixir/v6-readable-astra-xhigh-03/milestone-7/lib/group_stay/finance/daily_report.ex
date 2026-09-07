defmodule GroupStay.Finance.DailyReport do
  @moduledoc """
  Projects immutable entries into balances, ordinary movements and late adjustments.

  Both movement blocks affect balances. Omission checks examine classifications
  individually so a refund reversal and its chargeback remain visible even when
  they have no net effect on held cash.
  """
  import Ecto.Query

  alias GroupStay.Finance.Entry
  alias GroupStay.Repo

  @cash_columns [
    received: :received_cents,
    transferred_in: :transferred_in_cents,
    transferred_out: :transferred_out_cents,
    refunded: :refunded_cents,
    retained: :retained_cents,
    converted_to_credit: :converted_to_credit_cents,
    reduced: :reduced_cents,
    charged_back: :charged_back_cents
  ]
  @credit_columns [
    issued: :issued_cents,
    expired: :expired_cents,
    consumed: :consumed_cents,
    revoked: :revoked_cents,
    absorbed: :absorbed_cents
  ]

  # The caller holds a read transaction including inception and cutoff lookups.
  def build(date, status) do
    entries = Repo.all(from e in Entry, where: e.posted_on <= ^date)
    {cash, credit} = Enum.split_with(entries, &(&1.account == :cash))

    cash_summaries =
      cash
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(fn {property_id, _} -> property_id end)
      |> Enum.map(fn {property_id, entries} ->
        {row, late} =
          summarize(entries, date, @cash_columns, :opening_held_cents, :closing_held_cents)

        {Map.put(row, :property_id, property_id), %{property_id: property_id, movements: late}}
      end)

    cash =
      cash_summaries
      |> Enum.reject(fn {row, late} ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          zero_movements?(row.movements) and zero_movements?(late.movements)
      end)
      |> Enum.map(fn {row, _late} -> row end)

    late_cash =
      cash_summaries
      |> Enum.map(fn {_row, late} -> late end)
      |> Enum.reject(&zero_movements?(&1.movements))

    {credit, late_credit} =
      summarize(credit, date, @credit_columns, :opening_liability_cents, :closing_liability_cents)

    %{
      date: date,
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp summarize(entries, date, columns, opening_field, closing_field) do
    empty = Map.new(columns, fn {_, field} -> {field, 0} end)

    {opening, movements, late} =
      Enum.reduce(entries, {0, empty, empty}, fn entry, {opening, movements, late} ->
        cond do
          entry.kind == :opening or Date.compare(entry.posted_on, date) == :lt ->
            {opening + balance_change(entry.kind, entry.amount_cents), movements, late}

          entry.late_adjustment ->
            {opening, movements, add_movement(late, columns, entry)}

          true ->
            {opening, add_movement(movements, columns, entry), late}
        end
      end)

    change =
      Enum.reduce(columns, 0, fn {kind, column}, total ->
        total + balance_change(kind, Map.fetch!(movements, column) + Map.fetch!(late, column))
      end)

    {%{opening_field => opening, :movements => movements, closing_field => opening + change},
     late}
  end

  defp add_movement(movements, columns, entry) do
    column = Keyword.fetch!(columns, entry.kind)
    Map.update!(movements, column, &(&1 + entry.amount_cents))
  end

  defp zero_movements?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp balance_change(kind, amount) when kind in [:opening, :received, :transferred_in, :issued],
    do: amount

  defp balance_change(_kind, amount), do: -amount
end
