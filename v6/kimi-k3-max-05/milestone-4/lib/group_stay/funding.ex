defmodule GroupStay.Funding do
  @moduledoc """
  Cash funding of room deposits.

  Cash from each recorded payment (and the unattributed senior block of legacy
  funding, whose `payment_operation_id` is `nil`) fills active room deposits
  in the rooms' original order. Every cent of a payment stays allocated as it
  settles: held on a room, refunded, retained, converted to credit, reduced by
  a provider correction, or charged back. The allocations are the single
  source for the room paid amounts, the per-payment statement, and the cash
  ledger.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @doc """
  Allocates cash to the given rooms in order, filling one room's remaining
  deposit before moving to the next. The caller guarantees the amount fits.
  """
  def fill(%Group{} = group, rooms, amount, payment_operation_id) do
    Enum.reduce(rooms, amount, fn room, remaining ->
      need = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      take = min(remaining, max(need, 0))

      if take > 0 do
        insert_allocation!(group, room, payment_operation_id, take, "held")
        bump_room!(room, cash: take)
      end

      remaining - take
    end)

    :ok
  end

  @doc """
  Moves the held cash on the given rooms to the settlement status, returning
  the settled allocations (in fill order). The rooms' paid amounts are
  reduced; the rooms themselves are marked cancelled separately.
  """
  def settle(rooms, status) do
    rooms
    |> held_on_rooms()
    |> Enum.map(fn allocation ->
      bump_room!(allocation.room, cash: -allocation.amount_cents)
      update_status!(allocation, status)
    end)
  end

  @doc """
  The allocations of one payment in fill order.
  """
  def allocations(payment_operation_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_operation_id,
        order_by: [asc: a.id],
        preload: [:room]
    )
  end

  @doc """
  The current disposition of one payment's cash, summed by status.
  """
  def dispositions(payment_operation_id) do
    payment_operation_id
    |> allocations()
    |> Enum.reduce(%{}, fn allocation, sums ->
      Map.update(
        sums,
        allocation.status,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
  end

  @doc """
  Cash sums by disposition across all payments and the legacy block.
  """
  def totals_by_status do
    from(a in CashAllocation, group_by: a.status, select: {a.status, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Removes `amount` of the payment's held cash in reverse fill order, marking
  it reduced. The rooms' outstanding deposit reopens. Returns the total
  removed; the caller guarantees it does not exceed the held cash.
  """
  def reduce(payment_operation_id, amount) do
    payment_operation_id
    |> allocations()
    |> Enum.filter(&(&1.status == "held"))
    |> Enum.reverse()
    |> Enum.reduce(amount, fn allocation, remaining ->
      take = min(remaining, allocation.amount_cents)

      if take > 0 do
        bump_room!(allocation.room, cash: -take)
        split_off!(allocation, take, "reduced")
      end

      remaining - take
    end)

    :ok
  end

  @doc """
  Moves every remaining disposition of the payment (except cash already
  recorded as reduced) to charged-back cash. Held allocations are removed in
  reverse fill order, reopening the rooms' outstanding deposit. Returns the
  total moved and the portion that had been held.
  """
  def charge_back(payment_operation_id) do
    allocations = allocations(payment_operation_id)

    {total, held} =
      allocations
      |> Enum.filter(&(&1.status == "held"))
      |> Enum.reverse()
      |> Enum.reduce({0, 0}, fn allocation, {total, held} ->
        bump_room!(allocation.room, cash: -allocation.amount_cents)
        update_status!(allocation, "charged_back")
        {total + allocation.amount_cents, held + allocation.amount_cents}
      end)

    total =
      allocations
      |> Enum.filter(&(&1.status in ~w(refunded retained converted)))
      |> Enum.reduce(total, fn allocation, total ->
        update_status!(allocation, "charged_back")
        total + allocation.amount_cents
      end)

    {total, held}
  end

  defp held_on_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.status == "held",
        order_by: [asc: a.id],
        preload: [:room]
    )
  end

  defp insert_allocation!(group, room, payment_operation_id, amount, status) do
    %CashAllocation{}
    |> change(
      group_id: group.id,
      room_id: room.id,
      payment_operation_id: payment_operation_id,
      amount_cents: amount,
      status: status
    )
    |> Repo.insert!()
  end

  # Moves `amount` out of a held allocation into a new status: the whole row
  # flips when it is fully consumed, otherwise it splits.
  defp split_off!(allocation, amount, status) do
    if amount == allocation.amount_cents do
      update_status!(allocation, status)
    else
      allocation
      |> change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      %CashAllocation{}
      |> change(
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        status: status
      )
      |> Repo.insert!()
    end
  end

  defp update_status!(allocation, status) do
    allocation
    |> change(status: status)
    |> Repo.update!()
  end

  # Atomic increments avoid stale reads when several allocations of one
  # settlement touch the same room.
  defp bump_room!(%Room{} = room, cash: cash_delta) do
    Repo.update_all(
      from(r in Room, where: r.id == ^room.id),
      inc: [cash_paid_cents: cash_delta]
    )
  end
end
