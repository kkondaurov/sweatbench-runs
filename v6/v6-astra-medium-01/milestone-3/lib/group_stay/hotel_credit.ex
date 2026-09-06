defmodule GroupStay.HotelCredit do
  @moduledoc "Credit lots and their funding allocations; mutations run inside reservation transactions."
  import Ecto.Query
  alias GroupStay.{CreditAllocation, CreditLot, Repo}

  def available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  def balance(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    # Allocations exist only while funding an active group. Their expiry is paused.
    applied = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    available + applied
  end

  def issue(group, operation_id, on, amount) when amount > 0 do
    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      expires_on: Date.add(on, 365),
      remaining_cents: amount
    })
  end

  def issue(_, _, _, 0), do: :ok

  def redeem(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(lot.remaining_cents, needed)
      Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))

      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: used
      })

      if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  def settle(group, refundable, on) do
    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      # An expired restoration is permanently extinguished, not made available again.
      if refundable and Date.compare(lot.expires_on, on) != :lt do
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + allocation.amount_cents
          )
        )
      end

      Repo.delete!(allocation)
    end
  end
end
