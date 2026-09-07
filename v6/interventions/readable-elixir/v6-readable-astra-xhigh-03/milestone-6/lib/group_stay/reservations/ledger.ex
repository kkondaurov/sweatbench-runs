defmodule GroupStay.Reservations.Ledger do
  @moduledoc """
  A consistent snapshot of cash dispositions and outstanding credit liability.

  The date controls expiry of current unredeemed balances, rather than replaying
  history. Applied credit remains a liability, including any current shortfall.
  Queries share a read transaction; sums use Elixir integers so accumulated
  payments and cross-property totals cannot overflow SQLite.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, CreditLot, RoomCreditAllocation}

  def totals(on) do
    {:ok, totals} = Repo.transact(fn -> {:ok, snapshot(on)} end)
    totals
  end

  defp snapshot(on) do
    cash =
      Repo.all(from entry in CashEntry, select: {type(entry.kind, :string), entry.amount_cents})
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    applied =
      Repo.all(
        from allocation in RoomCreditAllocation,
          where: allocation.active,
          select: {allocation.credit_lot_id, allocation.amount_cents}
      )
      |> Enum.reduce(%{}, fn {lot, amount}, totals ->
        Map.update(totals, lot, amount, &(&1 + amount))
      end)

    {available, shortfall} =
      Enum.reduce(Repo.all(CreditLot), {0, 0}, fn lot, {available, shortfall} ->
        unexpired = if Date.compare(lot.expires_on, on) != :lt, do: lot.remaining_cents, else: 0

        {available + unexpired,
         shortfall + min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))}
      end)

    refunds = Map.get(cash, "refund", 0)
    retentions = Map.get(cash, "retention", 0)
    conversions = Map.get(cash, "credit_conversion", 0)
    reductions = Map.get(cash, "reduction", 0)
    chargebacks = Map.get(cash, "chargeback", 0)

    %{
      cash_held_cents:
        Map.get(cash, "payment", 0) - refunds - retentions - conversions - reductions -
          chargebacks,
      cash_refunded_cents: refunds,
      cash_retained_cents: retentions,
      cash_converted_to_credit_cents: conversions,
      cash_reduced_cents: reductions,
      cash_charged_back_cents: chargebacks,
      credit_liability_cents: available + Enum.sum(Map.values(applied)),
      credit_shortfall_cents: shortfall
    }
  end
end
