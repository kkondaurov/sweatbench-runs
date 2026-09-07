defmodule GroupStay.Credits do
  @moduledoc """
  Tracks available lots and credit funding active deposits separately. Reads
  evaluate expiry without mutating balances. Allocated credit stays a liability
  regardless of expiry until cancellation restores or consumes it.

  Mutations run inside the reservation operation's immediate transaction, so
  competing groups cannot spend the same guest balance.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Credits.{Allocation, Lot}

  def available(guest_id, on) do
    lots = Repo.all(available_query(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.one(
        from l in Lot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated = Repo.one(from a in Allocation, select: coalesce(sum(a.amount_cents), 0))
    available + allocated
  end

  def issue(group, source_operation_id, cash, on) do
    # Round the bonus independently, with exact half-cents rounded upward.
    amount = bonus_value(cash)

    lot =
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount,
        expires_on: Date.add(on, 365)
      })

    {lot, amount}
  end

  def apply(group, amount, on) do
    lots = Repo.all(available_query(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        used = min(needed, lot.remaining_cents)
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))

        GroupStay.Accounting.fund_credit(group, lot.id, used)

        if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
      end)

      :ok
    end
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def settle(group, room_ids, refundable?, on) do
    allocations =
      Repo.all(
        from a in Allocation,
          where: a.group_id == ^group.group_id and a.room_id in ^room_ids,
          order_by: a.id
      )

    for allocation <- allocations do
      if refundable? do
        lot = Repo.get!(Lot, allocation.credit_lot_id)
        absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

        restored =
          if Date.compare(lot.expires_on, on) == :lt,
            do: 0,
            else: allocation.amount_cents - absorbed

        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + restored,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
          )
        )
      end

      Repo.delete!(allocation)
    end
  end

  def claw_back(lot_id, entitlement) do
    lot = Repo.get!(Lot, lot_id)
    removed = min(lot.remaining_cents, entitlement)

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - removed
      )
    )
  end

  def shortfall do
    allocated =
      Repo.all(
        from a in Allocation,
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    Repo.all(Lot)
    |> Enum.map(&min(&1.unrecovered_clawback_cents, Map.get(allocated, &1.id, 0)))
    |> Enum.sum()
  end

  defp available_query(guest_id, on) do
    from l in Lot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
