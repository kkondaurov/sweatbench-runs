defmodule GroupStay.Credit do
  @moduledoc """
  Manages available lots and credit allocated to active deposits. Mutations run
  inside the reservation operation's transaction. Expiry is evaluated at the
  requested date without destroying balances during reads.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Credit.{Allocation, Lot}

  def available(guest_id, on) do
    lots = Repo.all(available_lots(on) |> where(guest_id: ^guest_id))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.one(from l in available_lots(on), select: coalesce(sum(l.remaining_cents), 0))

    allocated = Repo.one(from a in Allocation, select: coalesce(sum(a.amount_cents), 0))
    available + allocated
  end

  def issue(guest_id, cash, source_operation_id, on) do
    amount = bonus_value(cash)

    if amount > 0 do
      Repo.insert!(%Lot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount,
        expires_on: Date.add(on, 365)
      })
    end

    amount
  end

  def apply_to_group(group, amount, on) do
    lots = Repo.all(available_lots(on) |> where(guest_id: ^group.guest_id))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount,
      do: GroupStay.Operations.reject(%{code: "insufficient_credit"})

    Enum.reduce_while(lots, amount, fn lot, needed ->
      if needed == 0 do
        {:halt, 0}
      else
        used = min(needed, lot.remaining_cents)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        GroupStay.Accounting.fund_credit(group, lot.id, used)

        {:cont, needed - used}
      end
    end)
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def settle_rooms(group, room_ids, refundable, on) do
    allocations =
      Repo.all(
        from a in Allocation,
          where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.credit_lot_id)

      if refundable do
        absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)

        restored =
          if Date.compare(lot.expires_on, on) == :lt,
            do: 0,
            else: allocation.amount_cents - absorbed

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + restored,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end
  end

  def claw_back(lot_id, entitlement) do
    lot = Repo.get!(Lot, lot_id)
    removed = min(lot.remaining_cents, entitlement)

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents - removed,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - removed
    )
    |> Repo.update!()
  end

  def shortfall do
    Repo.all(from l in Lot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.map(fn lot ->
      applied =
        Repo.one(
          from a in Allocation,
            where: a.credit_lot_id == ^lot.id,
            select: coalesce(sum(a.amount_cents), 0)
        )

      min(applied, lot.unrecovered_clawback_cents)
    end)
    |> Enum.sum()
  end

  defp available_lots(on) do
    from l in Lot,
      where: l.remaining_cents > 0 and l.expires_on >= ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
