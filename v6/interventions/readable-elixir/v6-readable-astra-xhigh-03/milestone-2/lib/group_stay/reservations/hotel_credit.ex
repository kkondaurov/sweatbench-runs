defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Issues, redeems and restores guest-owned credit lots.

  Mutations run inside the reservations context's immediate transaction, so two
  groups cannot spend the same credit. Restoring a lot preserves its expiry:
  past-expiry balances are excluded from both availability and the liability.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot}

  def available(guest_id, on) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def issue(_group, _operation, _occurred_on, 0), do: :ok

  def issue(group, operation, occurred_on, amount) do
    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_group_id: group.group_id,
      source_operation_id: operation["operation_id"],
      issued_on: occurred_on,
      expires_on: Date.add(occurred_on, 365),
      issued_cents: amount,
      remaining_cents: amount
    })
  end

  def redeem(group, operation, occurred_on) do
    amount = operation["amount_cents"]
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        if needed == 0 do
          {:halt, 0}
        else
          redeemed = min(lot.remaining_cents, needed)
          Repo.update!(change(lot, remaining_cents: lot.remaining_cents - redeemed))

          Repo.insert!(%CreditAllocation{
            group_id: group.group_id,
            credit_lot_id: lot.id,
            operation_id: operation["operation_id"],
            occurred_on: occurred_on,
            amount_cents: redeemed
          })

          {:cont, needed - redeemed}
        end
      end)

      :ok
    end
  end

  def restore(group) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )

    Enum.each(allocations, fn {lot_id, amount} ->
      lot = Repo.get!(CreditLot, lot_id)
      Repo.update!(change(lot, remaining_cents: lot.remaining_cents + amount))
    end)
  end

  defp available_lots(guest_id, on) do
    from lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end
end
