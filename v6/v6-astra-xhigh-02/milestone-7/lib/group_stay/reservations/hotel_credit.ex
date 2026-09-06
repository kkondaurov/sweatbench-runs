defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc false
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditEntitlement, CreditLot, RoomAllocation}

  # Mutations run inside the reservation operation's immediate transaction.
  def available_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  def available_total(on) do
    Repo.all(from lot in CreditLot, where: lot.expires_on >= ^on, select: lot.remaining_cents)
    |> Enum.sum()
  end

  def shortfall_total do
    applied =
      Repo.all(
        from a in RoomAllocation,
          where: a.disposition == "held" and not is_nil(a.credit_lot_id),
          select: {a.credit_lot_id, a.amount_cents}
      )
      |> Enum.reduce(%{}, fn {id, amount}, totals ->
        Map.update(totals, id, amount, &(&1 + amount))
      end)

    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.map(&min(&1.unrecovered_clawback_cents, Map.get(applied, &1.id, 0)))
    |> Enum.sum()
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def issue(group, cash_allocations, operation_id, expires_on) do
    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    amount = bonus_value(cash)

    if amount > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: amount,
          expires_on: expires_on
        })

      # Credit is fungible after issuance. Only the entitlement created by each
      # payment is attributed, using differences of rounded running totals.
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {_, allocations} ->
        Enum.min(Enum.map(allocations, &{&1.funding_order, &1.id}))
      end)
      |> Enum.reduce(0, fn {payment_id, allocations}, preceding ->
        through = preceding + Enum.sum(Enum.map(allocations, & &1.amount_cents))

        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment_id,
          amount_cents: bonus_value(through) - bonus_value(preceding)
        })

        through
      end)
    end

    amount
  end

  def redeem(group, amount, on) do
    lots = available_lots(group.guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, %{code: "insufficient_credit"}}
    else
      {_, chunks} =
        Enum.reduce_while(lots, {amount, []}, fn lot, {needed, chunks} ->
          used = min(needed, lot.remaining_cents)
          update_lot(lot, remaining_cents: lot.remaining_cents - used)

          # Retain the original lot-consumption history, including after settlement.
          Repo.insert!(%CreditAllocation{
            group_id: group.group_id,
            credit_lot_id: lot.id,
            amount_cents: used
          })

          acc = {needed - used, [%{credit_lot_id: lot.id, amount_cents: used} | chunks]}
          if needed == used, do: {:halt, acc}, else: {:cont, acc}
        end)

      {:ok, Enum.reverse(chunks)}
    end
  end

  def restore(allocations, on) do
    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)
      absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
      excess = allocation.amount_cents - absorbed
      available = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: excess

      # Absorb clawbacks before expiry. Applied credit has remained a liability
      # even after expiry; only an unabsorbed, unexpired excess becomes available.
      update_lot(lot,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + available
      )
    end
  end

  def revoke(payment_id) do
    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment_id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      update_lot(lot,
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
    end
  end

  defp update_lot(lot, changes), do: lot |> Ecto.Changeset.change(changes) |> Repo.update!()
end
