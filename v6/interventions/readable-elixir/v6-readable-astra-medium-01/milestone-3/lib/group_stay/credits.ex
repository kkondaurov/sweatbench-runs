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
    amount = cash + div(cash * 10 + 50, 100)

    if amount > 0 do
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount,
        expires_on: Date.add(on, 365)
      })
    end

    amount
  end

  def apply(group, amount, on) do
    lots = Repo.all(available_query(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        used = min(needed, lot.remaining_cents)
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))

        Repo.insert!(%Allocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })

        if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
      end)

      :ok
    end
  end

  def settle(group, refundable?, on) do
    allocations = Repo.all(from a in Allocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.credit_lot_id)

      if refundable? and Date.compare(lot.expires_on, on) != :lt do
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + allocation.amount_cents
          )
        )
      end

      Repo.delete!(allocation)
    end
  end

  defp available_query(guest_id, on) do
    from l in Lot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
