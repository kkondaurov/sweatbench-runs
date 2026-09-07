defmodule GroupStay.Credits do
  @moduledoc """
  Hotel credit balances and the provenance of redeemed deposits.

  Available credit expires by calendar date; allocations remain liabilities
  regardless of expiry until settled. Reads project expiry without mutating
  balances. The `on` date is an expiry cutoff, not a historical account snapshot.
  Mutations run inside the reservation operation's write transaction.
  """
  import Ecto.Query
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.{Accounting, Repo}
  alias GroupStay.Accounting.CreditEntitlement

  def for_guest(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.all(from lot in Lot, where: lot.expires_on >= ^on, select: lot.remaining_cents)

    allocated = Repo.all(from allocation in Allocation, select: allocation.amount_cents)
    Enum.sum(available) + Enum.sum(allocated)
  end

  @doc "The principal plus its independently rounded ten-percent bonus."
  def bonus_value(cash), do: cash + div(cash + 5, 10)

  def issue(group, source_operation_id, occurred_on, cash_allocations) do
    amount = bonus_value(Accounting.sum(cash_allocations))

    if amount > 0 do
      lot =
        Repo.insert!(%Lot{
          guest_id: group.guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: amount,
          expires_on: Date.add(occurred_on, 365)
        })

      # Cash allocation IDs preserve funding order, including the senior block.
      cash_allocations
      |> Enum.chunk_by(& &1.payment_operation_id)
      |> Enum.reduce(0, fn allocations, running ->
        cash = Accounting.sum(allocations)

        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: hd(allocations).payment_operation_id,
          amount_cents: bonus_value(running + cash) - bonus_value(running)
        })

        running + cash
      end)
    end

    amount
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

  def revoke(payment_id) do
    entitlements =
      Repo.all(
        from e in CreditEntitlement, where: e.payment_operation_id == ^payment_id, order_by: e.id
      )

    for entitlement <- entitlements do
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
      |> Repo.update!()
    end
  end

  def apply_to_group(group, amount, occurred_on) do
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        redeemed = min(lot.remaining_cents, needed)
        change_remaining(lot, -redeemed)

        Accounting.fund_credit(group, lot.id, redeemed)

        if needed == redeemed, do: {:halt, 0}, else: {:cont, needed - redeemed}
      end)

      :ok
    end
  end

  def settle(group, room_ids, refundable?, occurred_on) do
    allocations =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids,
          order_by: allocation.id
      )

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.credit_lot_id)

      if refundable? do
        absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

        restored =
          if Date.compare(lot.expires_on, occurred_on) == :lt,
            do: 0,
            else: allocation.amount_cents - absorbed

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + restored,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      end

      # Non-refundable redemptions and already-expired restorations are consumed.
      Repo.delete!(allocation)
    end

    :ok
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.expires_on >= ^on and lot.remaining_cents > 0,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp change_remaining(lot, delta) do
    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + delta)
    |> Repo.update!()
  end
end
