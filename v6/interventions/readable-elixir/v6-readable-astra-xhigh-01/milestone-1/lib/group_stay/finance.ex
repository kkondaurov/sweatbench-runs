defmodule GroupStay.Finance do
  @moduledoc """
  Records deposit cash movements and reports their lifetime finance totals.
  Unpaid requirements never create cash entries. Reservation changes and their
  entries must be committed in the same transaction.
  """

  import Ecto.Query

  alias GroupStay.Finance.CashEntry
  alias GroupStay.Repo

  @doc "Returns held, refunded, and retained cash across all groups."
  def totals do
    # A group's cash fits in SQLite's integer range; lifetime totals across
    # groups may exceed it. Add those subtotals using Elixir's exact integers.
    amounts =
      Repo.all(
        from entry in CashEntry,
          group_by: [entry.group_id, entry.kind],
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    paid = Map.get(amounts, :payment, 0)
    refunded = Map.get(amounts, :refund, 0)
    retained = Map.get(amounts, :retention, 0)

    %{
      cash_held_cents: paid - refunded - retained,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained
    }
  end

  @doc false
  def record!(operation, occurred_on, kind, amount_cents) when amount_cents > 0 do
    Repo.insert!(%CashEntry{
      group_id: operation.group_id,
      operation_id: operation.operation_id,
      occurred_on: occurred_on,
      kind: kind,
      amount_cents: amount_cents
    })
  end

  def record!(_operation, _occurred_on, _kind, 0), do: :ok
end
