defmodule GroupStay.Finance.DailyReport do
  @moduledoc "Projects immutable reporting entries into opening balances and daily movements."
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

  # The caller holds a read transaction including the inception lookup.
  def build(date) do
    entries = Repo.all(from e in Entry, where: e.posted_on <= ^date)
    {cash, credit} = Enum.split_with(entries, &(&1.account == :cash))

    cash =
      cash
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(fn {property_id, _} -> property_id end)
      |> Enum.map(fn {property_id, entries} ->
        entries
        |> summarize(date, @cash_columns, :opening_held_cents, :closing_held_cents)
        |> Map.put(:property_id, property_id)
      end)
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(row.movements, fn {_, amount} -> amount == 0 end)
      end)

    %{
      date: date,
      status: "open",
      cash: cash,
      credit:
        summarize(
          credit,
          date,
          @credit_columns,
          :opening_liability_cents,
          :closing_liability_cents
        )
    }
  end

  defp summarize(entries, date, columns, opening_field, closing_field) do
    {opening, movements} =
      Enum.reduce(entries, {0, Map.new(columns, fn {_, field} -> {field, 0} end)}, fn
        entry, {opening, movements} ->
          if entry.kind == :opening or Date.compare(entry.posted_on, date) == :lt do
            {opening + balance_change(entry.kind, entry.amount_cents), movements}
          else
            column = Keyword.fetch!(columns, entry.kind)
            {opening, Map.update!(movements, column, &(&1 + entry.amount_cents))}
          end
      end)

    change =
      Enum.reduce(columns, 0, fn {kind, column}, total ->
        total + balance_change(kind, Map.fetch!(movements, column))
      end)

    %{opening_field => opening, :movements => movements, closing_field => opening + change}
  end

  defp balance_change(kind, amount) when kind in [:opening, :received, :transferred_in, :issued],
    do: amount

  defp balance_change(_kind, amount), do: -amount
end
