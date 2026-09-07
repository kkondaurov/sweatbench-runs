defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Allocates funding in booking order and maintains active-room deposit balances.
  Funding slices are persisted separately so settled cash remains reconcilable.
  All mutations run within the partner operation transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation}

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1.status == "active"))
    cash = sum(active, :cash_paid_cents)
    credit = sum(active, :credit_paid_cents)

    %{
      lodging_total_cents: sum(active, :lodging_total_cents),
      deposit_due_cents: sum(active, :deposit_due_cents),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  def changes(rooms), do: Map.put(totals(rooms), :rooms, rooms)

  def fund(rooms, amount, kind, persist) do
    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        used = if room.status == "active", do: min(capacity, remaining), else: 0
        if used > 0, do: persist.(room.room_id, used)
        {Map.update!(room, kind, &(&1 + used)), remaining - used}
      end)

    rooms
  end

  def cash(group, payment_id, amount) do
    fund(group.rooms, amount, :cash_paid_cents, fn room_id, used ->
      Repo.insert!(%CashAllocation{
        allocation_order: next_position(),
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: used
      })
    end)
  end

  def credit(group, rooms, lot_id, amount) do
    fund(rooms, amount, :credit_paid_cents, fn room_id, used ->
      Repo.insert!(%CreditAllocation{
        allocation_order: next_position(),
        group_id: group.group_id,
        room_id: room_id,
        credit_lot_id: lot_id,
        amount_cents: used
      })
    end)
  end

  def selected_cash(group, room_ids) do
    Repo.all(
      from a in CashAllocation,
        where:
          a.group_id == ^group.group_id and a.room_id in ^room_ids and a.disposition == "held",
        order_by: a.allocation_order
    )
  end

  @doc "Moves part of a slice, preserving the original slice's fill position."
  def move(allocation, amount, disposition, lot_id \\ nil) do
    if amount == allocation.amount_cents do
      allocation
      |> Ecto.Changeset.change(disposition: disposition, credit_lot_id: lot_id)
      |> Repo.update!()
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      Repo.insert!(%CashAllocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        disposition: disposition,
        credit_lot_id: lot_id
      })
    end
  end

  def remove_cash(rooms, allocations, amount, disposition) do
    {rooms, 0} =
      Enum.reduce(allocations, {rooms, amount}, fn allocation, {rooms, remaining} ->
        used = min(allocation.amount_cents, remaining)
        if used > 0, do: move(allocation, used, disposition)

        rooms =
          Enum.map(rooms, fn room ->
            if room.room_id == allocation.room_id,
              do: %{room | cash_paid_cents: room.cash_paid_cents - used},
              else: room
          end)

        {rooms, remaining - used}
      end)

    rooms
  end

  @doc "A shared, durable creation order for cash and credit slices."
  def next_position do
    %{rows: [[id]]} = Repo.query!("INSERT INTO allocation_positions DEFAULT VALUES RETURNING id")
    id
  end

  defp sum(rooms, field), do: Enum.sum(Enum.map(rooms, &Map.fetch!(&1, field)))
end
