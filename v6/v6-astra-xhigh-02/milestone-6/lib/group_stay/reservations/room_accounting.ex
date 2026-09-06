defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Tracks funding through room settlement without reallocating surviving deposits.

  Allocation splits preserve their original funding order. Historical dispositions
  remain here so a payment's statement and a later chargeback use the same cash.
  All mutations run within the partner operation's transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.RoomAllocation

  def held(group_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_id and a.disposition == "held" and a.amount_cents > 0,
        order_by: [asc: a.funding_order, asc: a.id]
    )
  end

  def allocate(group, chunks) do
    balances = Enum.group_by(held(group.group_id), & &1.room_id)

    capacity =
      for room <- group.rooms, room.status == "active" do
        paid = balances |> Map.get(room.room_id, []) |> total()
        {room.room_id, room.deposit_due_cents - paid}
      end

    order =
      (Repo.one(
         from a in RoomAllocation,
           where: a.group_id == ^group.group_id,
           select: max(a.funding_order)
       ) || 0) + 1

    Enum.reduce(chunks, capacity, fn chunk, capacity ->
      fill(capacity, chunk.amount_cents, Map.put(chunk, :funding_order, order), group.group_id)
    end)

    :ok
  end

  defp fill(capacity, 0, _, _), do: capacity
  defp fill([{_, 0} | rest], needed, chunk, group_id), do: fill(rest, needed, chunk, group_id)

  defp fill([{room_id, available} | rest], needed, chunk, group_id) do
    used = min(needed, available)

    Repo.insert!(
      struct!(
        RoomAllocation,
        Map.merge(chunk, %{group_id: group_id, room_id: room_id, amount_cents: used})
      )
    )

    fill([{room_id, available - used} | rest], needed - used, chunk, group_id)
  end

  def totals(group, cancelled_ids \\ []) do
    balances = Enum.group_by(held(group.group_id), & &1.room_id)

    rooms =
      Enum.map(group.rooms, fn room ->
        allocations = Map.get(balances, room.room_id, [])
        {cash, credit} = Enum.split_with(allocations, &is_nil(&1.credit_lot_id))
        cancelled? = room.status == "cancelled" or room.room_id in cancelled_ids

        %{
          room
          | status: if(cancelled?, do: "cancelled", else: "active"),
            deposit_due_cents: if(cancelled?, do: 0, else: room.deposit_due_cents),
            cash_paid_cents: total(cash),
            credit_paid_cents: total(credit)
        }
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    [
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    ]
  end

  def move(allocation, amount, disposition) when amount > 0 do
    if amount == allocation.amount_cents do
      allocation |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      allocation
      |> Map.from_struct()
      |> Map.drop([:id, :__meta__])
      |> Map.merge(%{amount_cents: amount, disposition: disposition})
      |> then(&struct!(RoomAllocation, &1))
      |> Repo.insert!()
    end
  end

  def remove_held(allocations, amount, disposition) do
    allocations
    |> draw_held(amount)
    |> Enum.map(fn {allocation, used} -> move(allocation, used, disposition) end)
  end

  def transfer(source, destination, amount) do
    chunks =
      source.group_id
      |> held()
      |> draw_held(amount)
      |> Enum.map(fn {allocation, used} ->
        if used == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - used)
          |> Repo.update!()
        end

        %{
          payment_operation_id: allocation.payment_operation_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: used,
          transferred: true
        }
      end)

    allocate(destination, chunks)
  end

  # IDs give allocation creation order across groups; funding_order is local to
  # a group and cannot order a payment's funding after transfers. Partial draws
  # keep the surviving held allocation's age, while destination fills get new IDs.
  defp draw_held(allocations, amount) do
    allocations
    |> Enum.filter(&(&1.disposition == "held"))
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.reduce_while({amount, []}, fn allocation, {needed, drawn} ->
      used = min(needed, allocation.amount_cents)
      drawn = if used > 0, do: [{allocation, used} | drawn], else: drawn
      acc = {needed - used, drawn}
      if needed == used, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  def total(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))
end
