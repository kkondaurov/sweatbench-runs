defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc false
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot}

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

  def issue(group, operation_id, expires_on) do
    amount = group.cash_paid_cents + div(group.cash_paid_cents * 10 + 50, 100)

    if amount > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: expires_on
      })
    end

    amount
  end

  def redeem(group, amount, on) do
    lots = available_lots(group.guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, %{code: "insufficient_credit"}}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        used = min(needed, lot.remaining_cents)
        set_remaining(lot, lot.remaining_cents - used)

        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })

        if needed == used, do: {:halt, 0}, else: {:cont, needed - used}
      end)

      :ok
    end
  end

  def restore(group, on) do
    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      # Redeemed credit stays a liability after expiry while the group is active.
      # Once released after its expiry it is extinguished, even for backdated reads.
      if Date.compare(lot.expires_on, on) != :lt do
        set_remaining(lot, lot.remaining_cents + allocation.amount_cents)
      end
    end

    :ok
  end

  defp set_remaining(lot, amount) do
    lot |> Ecto.Changeset.change(remaining_cents: amount) |> Repo.update!()
  end
end
