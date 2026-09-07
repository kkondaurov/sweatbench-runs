defmodule GroupStay.HotelCredit do
  @moduledoc """
  Manages credit lots and the allocations that pause expiry while funding a group.

  Mutations run inside the reservation operation's transaction. Reads evaluate
  expiry without modifying balances; `on` selects an expiry date, not a historical
  snapshot of previously applied operations.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.HotelCredit.{Allocation, Lot}

  def balance(guest_id, on) do
    lots = Repo.all(available(guest_id, on))

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

  def issue(_group, _operation_id, 0, _on), do: 0

  def issue(group, operation_id, cash, on) do
    amount = cash + div(cash * 10 + 50, 100)

    Repo.insert!(%Lot{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: amount,
      expires_on: Date.add(on, 365)
    })

    amount
  end

  def apply(group, amount, on) do
    lots = Repo.all(available(group.guest_id, on))

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

    :ok
  end

  defp available(guest_id, on) do
    from l in Lot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
