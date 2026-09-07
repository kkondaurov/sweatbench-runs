defmodule GroupStay.Finance do
  @moduledoc """
  Records deposit cash movements and reports their lifetime finance totals.
  Unpaid requirements never create cash entries. Reservation changes and their
  entries must be committed in the same transaction.
  """

  import Ecto.Query

  alias GroupStay.Finance.CashEntry
  alias GroupStay.{Credits, Repo}

  @doc "Returns cumulative cash totals and the credit liability at the requested expiry date."
  def totals(on \\ Date.utc_today()) do
    # A read transaction keeps cash, available lots, and applied credit in the
    # same snapshot while another request may be settling or allocating them.
    {:ok, totals} =
      Repo.transaction(fn ->
        Map.put(cash_totals(), :credit_liability_cents, Credits.liability_cents(on))
      end)

    totals
  end

  defp cash_totals do
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
    converted = Map.get(amounts, :credit_conversion, 0)

    %{
      cash_held_cents: paid - refunded - retained - converted,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted
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
