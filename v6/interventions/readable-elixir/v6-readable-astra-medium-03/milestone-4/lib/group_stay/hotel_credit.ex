defmodule GroupStay.HotelCredit do
  @moduledoc """
  Manages credit lots and the allocations that pause expiry while funding a group.

  Mutations run inside the reservation operation's transaction. Reads evaluate
  expiry without modifying balances; `on` selects an expiry date, not a historical
  snapshot of previously applied operations.

  A clawback first revokes unspent credit. Its unrecovered balance is separate
  from the current shortfall, which is capped by credit still funding groups.
  Refundable restorations absorb that balance before availability or expiry.
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

  def shortfall do
    applied =
      Repo.all(
        from a in Allocation,
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    Repo.all(Lot)
    |> Enum.map(&min(&1.unrecovered_clawback_cents, Map.get(applied, &1.id, 0)))
    |> Enum.sum()
  end

  def issue_lot(_group, _operation_id, 0, _on), do: {0, nil}

  def issue_lot(group, operation_id, cash, on) do
    amount = cash + div(cash * 10 + 50, 100)

    lot =
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: Date.add(on, 365)
      })

    {amount, lot.id}
  end

  def consume(guest_id, amount, on) do
    lots = Repo.all(available(guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      {0, consumed} =
        Enum.reduce(lots, {amount, []}, fn lot, {needed, consumed} ->
          used = min(needed, lot.remaining_cents)

          if used > 0 do
            Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))
            {needed - used, [{lot, used} | consumed]}
          else
            {needed, consumed}
          end
        end)

      {:ok, Enum.reverse(consumed)}
    end
  end

  def revoke(lot_id, entitlement) do
    lot = Repo.get!(Lot, lot_id)
    removed = min(lot.remaining_cents, entitlement)

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - removed
      )
    )
  end

  def settle_rooms(group_id, room_ids, refundable?, on) do
    allocations =
      Repo.all(
        from a in Allocation,
          where: a.group_id == ^group_id and a.room_id in ^room_ids,
          order_by: a.id
      )

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.credit_lot_id)

      if refundable? do
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

    :ok
  end

  defp available(guest_id, on) do
    from l in Lot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
