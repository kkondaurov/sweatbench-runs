defmodule GroupStay.Finance do
  @moduledoc """
  Records deposit cash movements and reports their lifetime finance totals.
  Unpaid requirements never create cash entries. Reservation changes and their
  entries must be committed in the same transaction.
  """

  import Ecto.Query

  alias GroupStay.Finance.{CashAllocation, CashEntry, Reporting}
  alias GroupStay.{Credits, Repo}

  @doc "Returns current cash dispositions, credit liability, and credit shortfall."
  def totals(on \\ Date.utc_today()) do
    # A read transaction keeps cash, available lots, and applied credit in the
    # same snapshot while another request may be settling or allocating them.
    {:ok, totals} =
      Repo.transaction(fn ->
        cash_totals()
        |> Map.put(:credit_liability_cents, Credits.liability_cents(on))
        |> Map.put(:credit_shortfall_cents, Credits.shortfall_cents())
      end)

    totals
  end

  defp cash_totals do
    # Lifetime funding can exceed SQLite's integer range even within one group
    # after repeated reductions and refills. Sum individual portions in Elixir.
    amounts =
      Repo.all(
        from allocation in CashAllocation,
          select: {allocation.disposition, allocation.amount_cents}
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    %{
      cash_held_cents: Map.get(amounts, :held, 0),
      cash_refunded_cents: Map.get(amounts, :refunded, 0),
      cash_retained_cents: Map.get(amounts, :retained, 0),
      cash_converted_to_credit_cents: Map.get(amounts, :converted_to_credit, 0),
      cash_reduced_cents: Map.get(amounts, :reduced, 0),
      cash_charged_back_cents: Map.get(amounts, :charged_back, 0)
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

    # Corrections journal their individual allocations in Payments because the
    # affected cash can belong to several holding or settlement properties.
    classification =
      %{
        payment: :received_cents,
        refund: :refunded_cents,
        retention: :retained_cents,
        credit_conversion: :converted_to_credit_cents
      }[kind]

    if classification do
      Reporting.cash!(operation, operation.group_id, %{classification => amount_cents})
    end
  end

  def record!(_operation, _occurred_on, _kind, 0), do: :ok
end
