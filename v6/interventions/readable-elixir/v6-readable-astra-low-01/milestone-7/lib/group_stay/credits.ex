defmodule GroupStay.Credits do
  @moduledoc """
  Issues, allocates and settles hotel credit. Mutations run inside the reservation
  operation's write transaction. Available balances exclude expired lots; allocations
  remain liabilities regardless of the original expiry while a group is active.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Finance}
  alias GroupStay.Credits.{Allocation, Lot}

  def available(guest_id, on) do
    lots =
      Repo.all(
        from l in available_lots(on),
          where: l.guest_id == ^guest_id,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    Repo.one(from l in available_lots(on), select: coalesce(sum(l.remaining_cents), 0)) +
      Repo.one(from a in Allocation, select: coalesce(sum(a.amount_cents), 0))
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

    Finance.credit_movement("issued_cents", amount, on)
    Finance.credit_availability_change(amount, Date.add(on, 365), on)
    amount
  end

  def apply(group, amount, on) do
    lots =
      Repo.all(
        from l in available_lots(on),
          where: l.guest_id == ^group.guest_id,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        used = min(needed, lot.remaining_cents)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        Finance.credit_availability_change(-used, lot.expires_on, on)
        GroupStay.RoomAccounting.fund_credit(group, lot.id, used)
        if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
      end)

      :ok
    end
  end

  def settle(group, room_ids, refundable, on) do
    allocations =
      Repo.all(
        from a in Allocation, where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.lot_id)

      if refundable do
        absorbed = min(lot.unrecovered_cents, allocation.amount_cents)

        restored =
          if Date.compare(lot.expires_on, on) == :lt,
            do: 0,
            else: allocation.amount_cents - absorbed

        Finance.credit_availability_change(restored, lot.expires_on, on)
        Finance.credit_movement("absorbed_cents", absorbed, on)

        Finance.credit_movement(
          "expired_cents",
          allocation.amount_cents - absorbed - restored,
          on
        )

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + restored,
          unrecovered_cents: lot.unrecovered_cents - absorbed
        )
        |> Repo.update!()
      else
        Finance.credit_movement("consumed_cents", allocation.amount_cents, on)
      end

      Repo.delete!(allocation)
    end

    :ok
  end

  def claw_back(lot_id, entitlement, on) do
    lot = Repo.get!(Lot, lot_id)
    removed = min(lot.remaining_cents, entitlement)
    Finance.credit_revoked(removed, lot.expires_on, on)

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents - removed,
      unrecovered_cents: lot.unrecovered_cents + entitlement - removed
    )
    |> Repo.update!()
  end

  def shortfall do
    applied =
      from a in Allocation,
        group_by: a.lot_id,
        select: %{lot_id: a.lot_id, amount_cents: sum(a.amount_cents)}

    Repo.one(
      from l in Lot,
        join: a in subquery(applied),
        on: a.lot_id == l.id,
        select: coalesce(sum(fragment("min(?, ?)", l.unrecovered_cents, a.amount_cents)), 0)
    )
  end

  defp available_lots(on) do
    from l in Lot, where: l.expires_on >= ^on and l.remaining_cents > 0
  end
end
