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

  def redeem(group, lots, amount, operation) do
    {group, 0} =
      Enum.reduce_while(lots, {group, amount}, fn lot, {group, needed} ->
        used = min(lot.remaining_cents, needed)
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))
        group = GroupStay.RoomAccounting.allocate(group, used, operation, lot.id)
        if used == needed, do: {:halt, {group, 0}}, else: {:cont, {group, needed - used}}
      end)

    group
  end

  def restore(allocation, true, on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    # Recovery takes precedence over expiry; only the excess may become available.
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

    available =
      if Date.compare(lot.expires_on, on) == :lt, do: 0, else: allocation.amount_cents - absorbed

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: lot.remaining_cents + available,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
    )
  end

  def restore(_, false, _), do: :ok

  def shortfall do
    Repo.one(
      from l in CreditLot,
        select:
          coalesce(
            sum(
              fragment(
                "min(?, (SELECT coalesce(sum(amount_cents), 0) FROM credit_allocations WHERE credit_lot_id = ?))",
                l.unrecovered_clawback_cents,
                l.id
              )
            ),
            0
          )
    )
  end
end
