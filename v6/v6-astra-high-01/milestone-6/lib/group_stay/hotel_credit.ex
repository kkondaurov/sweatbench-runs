defmodule GroupStay.HotelCredit do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias GroupStay.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Operation,
    Operations,
    Repo,
    RoomAccounting
  }

  def available(guest_id, on) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def available_liability(on) do
    Repo.all(from l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents)
    |> Enum.sum()
  end

  # All mutations run within the reservation operation's IMMEDIATE transaction.
  def issue(group, operation_id, date, cash_allocations) do
    cash = RoomAccounting.sum(cash_allocations)
    amount = bonus(cash)

    if amount > 9_223_372_036_854_775_807,
      do: Operations.reject(%{code: "invalid_amount"})

    if amount > 0 do
      expires_on = Date.add(date, 365)
      if expires_on.year > 9999, do: Operations.reject(%{code: "invalid_operation"})

      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: amount,
          expires_on: expires_on
        })

      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {payment, _} ->
        if payment, do: Repo.get_by!(Operation, operation_id: payment).id, else: 0
      end)
      |> Enum.reduce(0, fn {payment, allocations}, running ->
        total = running + RoomAccounting.sum(allocations)

        if payment do
          Repo.insert!(%CreditEntitlement{
            payment_operation_id: payment,
            credit_lot_id: lot.id,
            amount_cents: bonus(total) - bonus(running)
          })
        end

        total
      end)

      {amount, lot.id}
    else
      {0, nil}
    end
  end

  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)

  def apply(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount,
      do: Operations.reject(%{code: "insufficient_credit"})

    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      change_remaining(lot, -used)
      RoomAccounting.allocate(group, "credit", used, credit_lot_id: lot.id)

      change_applied(group.group_id, lot.id, used)

      if needed == used, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  def settle(allocations, refundable, on) do
    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable do
        absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
        restored = allocation.amount_cents - absorbed
        available = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: restored

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + available,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      end

      change_applied(allocation.group_id, allocation.credit_lot_id, -allocation.amount_cents)

      RoomAccounting.move(
        allocation,
        allocation.amount_cents,
        if(refundable, do: "restored", else: "consumed")
      )
    end
  end

  def revoke(payment_id) do
    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment_id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
      |> Repo.update!()
    end
  end

  def change_applied(group_id, lot_id, delta) do
    allocation = Repo.get_by(CreditAllocation, group_id: group_id, credit_lot_id: lot_id)
    amount = if allocation, do: allocation.amount_cents + delta, else: delta
    if amount < 0, do: raise("credit allocation cannot be negative")

    cond do
      allocation && amount == 0 ->
        Repo.delete!(allocation)

      allocation ->
        allocation |> Ecto.Changeset.change(amount_cents: amount) |> Repo.update!()

      amount > 0 ->
        Repo.insert!(%CreditAllocation{
          group_id: group_id,
          credit_lot_id: lot_id,
          amount_cents: amount
        })
    end
  end

  def shortfall do
    Repo.all(
      from l in CreditLot,
        join: a in CreditAllocation,
        on: a.credit_lot_id == l.id,
        group_by: [l.id, l.unrecovered_clawback_cents],
        select: {l.unrecovered_clawback_cents, sum(a.amount_cents)}
    )
    |> Enum.map(fn {unrecovered, applied} -> min(unrecovered, applied) end)
    |> Enum.sum()
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  defp change_remaining(lot, delta) do
    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + delta)
    |> Repo.update!()
  end
end
