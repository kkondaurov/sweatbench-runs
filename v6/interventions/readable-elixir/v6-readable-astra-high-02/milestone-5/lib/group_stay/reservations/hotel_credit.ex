defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Manages guest credit lots and their allocation to deposits.

  Mutations run inside the reservation operation's immediate transaction. Credit is
  checked in full before consuming any lots. Allocations keep original lot provenance
  and pause expiry; refundable settlement restores only amounts still valid on the
  cancellation date. Expired restorations and non-refundable allocations are consumed.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2, put_change: 3]

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    RoomAccounting
  }

  def balance(guest_id, on) do
    lots =
      guest_id
      |> available_lots(on)
      |> Enum.map(&Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  @doc "Available liability; the ledger separately includes credit funding active groups."
  def available_liability(on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.expires_on >= ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
    )
  end

  def apply_to_group(group, amount, occurred_on) do
    with {:ok, changeset, result} <- Group.pay(group, amount) do
      lots = available_lots(group.guest_id, occurred_on)

      if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
        {:error, "insufficient_credit"}
      else
        allocate(group, lots, amount)
        {:ok, put_change(changeset, :credit_paid_cents, group.credit_paid_cents + amount), result}
      end
    end
  end

  @doc "Issues one lot with telescoping entitlements in the original funding order."
  def issue(_group, _operation_id, _date, []), do: 0

  def issue(group, operation_id, date, cash) do
    # A payment can span multiple rooms. Gather it before rounding so each
    # payment receives one contiguous entitlement in the lot's funding order.
    contributions =
      Enum.reduce(cash, [], fn allocation, contributions ->
        id = allocation.payment_operation_id

        case List.keyfind(contributions, id, 0) do
          nil ->
            contributions ++ [{id, allocation.amount_cents}]

          {^id, amount} ->
            List.keyreplace(contributions, id, 0, {id, amount + allocation.amount_cents})
        end
      end)

    issued = bonus(RoomAccounting.total(cash))

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        expires_on: Date.add(date, 365),
        remaining_cents: issued
      })

    Enum.reduce(contributions, 0, fn {payment, amount}, running ->
      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment,
        amount_cents: bonus(running + amount) - bonus(running)
      })

      running + amount
    end)

    issued
  end

  def settle_allocations(group, allocations, date, refundable?) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, slices} ->
      amount = RoomAccounting.total(slices)
      if refundable?, do: restore(lot_id, amount, date)
      adjust_applied(group, lot_id, -amount)

      Enum.each(slices, &Repo.delete!/1)
    end)
  end

  @doc "Moves applied credit between groups without touching its lot or resuming expiry."
  def transfer(source, destination, lot_id, amount) do
    adjust_applied(source, lot_id, -amount)
    adjust_applied(destination, lot_id, amount)
  end

  @doc "Revokes unspent entitlement first, retaining any unrecovered clawback."
  def revoke(lot_id, amount) do
    lot = Repo.get!(CreditLot, lot_id)
    removed = min(lot.remaining_cents, amount)

    lot
    |> change(
      remaining_cents: lot.remaining_cents - removed,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - removed
    )
    |> Repo.update!()
  end

  def current_shortfall do
    Repo.all(
      from lot in CreditLot,
        left_join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        group_by: lot.id,
        select: {lot.unrecovered_clawback_cents, coalesce(sum(allocation.amount_cents), 0)}
    )
    |> Enum.map(fn {unrecovered, applied} -> min(unrecovered, applied) end)
    |> Enum.sum()
  end

  defp restore(lot_id, amount, date) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    available = if Date.compare(lot.expires_on, date) == :lt, do: 0, else: amount - absorbed

    lot
    |> change(
      remaining_cents: lot.remaining_cents + available,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    )
    |> Repo.update!()
  end

  defp bonus(cents), do: cents + div(cents * 10 + 50, 100)

  defp available_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.expires_on >= ^on and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp allocate(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      RoomAccounting.allocate(group, used, credit_lot_id: lot.id)
      lot |> change(remaining_cents: lot.remaining_cents - used) |> Repo.update!()

      adjust_applied(group, lot.id, used)

      if needed == used, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  defp adjust_applied(group, lot_id, delta) do
    case Repo.get_by(CreditAllocation, group_id: group.group_id, credit_lot_id: lot_id) do
      nil when delta > 0 ->
        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot_id,
          amount_cents: delta
        })

      allocation when allocation.amount_cents + delta == 0 ->
        Repo.delete!(allocation)

      allocation ->
        allocation |> change(amount_cents: allocation.amount_cents + delta) |> Repo.update!()
    end
  end
end
