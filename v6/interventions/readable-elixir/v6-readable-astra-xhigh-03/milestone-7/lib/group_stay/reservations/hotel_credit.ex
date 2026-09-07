defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Issues, redeems and restores guest-owned credit lots.

  Mutations run inside the reservations context's immediate transaction, so two
  groups cannot spend the same credit. Restoring a lot preserves its expiry:
  past-expiry balances are excluded from both availability and the liability.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.{Finance, Repo}

  alias GroupStay.Reservations.{
    AllocationOrder,
    CancellationSettlement,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    RoomAccounting,
    RoomCreditAllocation
  }

  def available(guest_id, on) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def issue(_group, _operation, _occurred_on, 0), do: nil

  def issue(group, operation, occurred_on, amount) do
    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_group_id: group.group_id,
        source_operation_id: operation["operation_id"],
        issued_on: occurred_on,
        expires_on: Date.add(occurred_on, 365),
        issued_cents: amount,
        remaining_cents: amount
      })

    Finance.record_credit(lot, operation, occurred_on, :issued, amount)
    lot
  end

  def redeem(group, operation, occurred_on) do
    amount = operation["amount_cents"]
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      {0, rooms} =
        Enum.reduce(lots, {amount, group.rooms}, fn lot, {needed, rooms} ->
          redeemed = min(lot.remaining_cents, needed)

          if redeemed == 0 do
            {needed, rooms}
          else
            Repo.update!(change(lot, remaining_cents: lot.remaining_cents - redeemed))
            Finance.record_credit(lot, operation, occurred_on, :applied, redeemed)

            allocation =
              Repo.insert!(%CreditAllocation{
                group_id: group.group_id,
                credit_lot_id: lot.id,
                operation_id: operation["operation_id"],
                occurred_on: occurred_on,
                amount_cents: redeemed
              })

            {rooms, portions} = RoomAccounting.fund(rooms, redeemed, :credit_paid_cents)

            Enum.each(portions, fn {room_id, portion} ->
              AllocationOrder.insert!(%RoomCreditAllocation{
                group_id: group.group_id,
                room_id: room_id,
                credit_lot_id: lot.id,
                credit_allocation_id: allocation.id,
                amount_cents: portion
              })
            end)

            {needed - redeemed, rooms}
          end
        end)

      {:ok, rooms}
    end
  end

  def settle_rooms(group_id, room_ids, restore?, operation, occurred_on) do
    allocations =
      Repo.all(
        from allocation in RoomCreditAllocation,
          where:
            allocation.group_id == ^group_id and allocation.room_id in ^room_ids and
              allocation.active
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      lot = Repo.get!(CreditLot, lot_id)
      amount = Enum.sum(amounts)

      if restore? do
        restore(lot, amount, operation, occurred_on)
      else
        Finance.record_credit(lot, operation, occurred_on, :consumed, amount)
      end
    end)

    Enum.each(allocations, &Repo.update!(change(&1, active: false)))
  end

  @doc "Partitions a new lot's entitlement in cash funding order, rounding running totals."
  def assign_entitlements(lot, cash_allocations) do
    cash_allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {payment_id, allocations} ->
      {if(is_nil(payment_id), do: 0, else: 1),
       Enum.min(Enum.map(allocations, & &1.allocation_order))}
    end)
    |> Enum.reduce(0, fn {payment_id, allocations}, previous ->
      cash = Enum.reduce(allocations, 0, &(&2 + &1.held_cents))

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        amount_cents:
          CancellationSettlement.credit_value(previous + cash) -
            CancellationSettlement.credit_value(previous)
      })

      previous + cash
    end)

    :ok
  end

  def revoke_entitlements(payment_id, operation, occurred_on) do
    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          where: entitlement.payment_operation_id == ^payment_id
      )

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)
      Finance.record_credit(lot, operation, occurred_on, :revoked, revoked)

      Repo.update!(
        change(lot,
          remaining_cents: lot.remaining_cents - revoked,
          unrecovered_clawback_cents:
            lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
        )
      )
    end)
  end

  defp restore(lot, amount, operation, occurred_on) do
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    Finance.record_credit(lot, operation, occurred_on, :absorbed, absorbed)
    Finance.record_credit(lot, operation, occurred_on, :restored, amount - absorbed)
    # Absorb clawback before expiry. Any excess keeps the original expiry and
    # is excluded by date-based reads once expired, just like earlier releases.
    Repo.update!(
      change(lot,
        remaining_cents: lot.remaining_cents + amount - absorbed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
    )
  end

  defp available_lots(guest_id, on) do
    from lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end
end
