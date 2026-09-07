defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Prices rooms and allocates new funding to active deposits in original room order.

  Room prices remain available after cancellation; current funding counts only
  held cash and applied credit. Group balance columns cache sums of active rooms
  and are refreshed in the same transaction as each accounting mutation.

  Cash and credit share allocation creation order. Transfers draw newest first;
  destination portions receive new positions while a source remainder keeps its
  position. Payment and lot provenance survive each move and later settlement.
  """

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Finance.{CashAllocation, Reporting}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Pricing, Room}

  def rooms(group) do
    cash = balances(CashAllocation, group.group_id, :disposition, :held)
    credit = balances(Allocation, group.group_id, :status, :applied)
    nights = Date.diff(group.departure_on, group.arrival_on)

    Repo.all(from room in Room, where: room.group_id == ^group.group_id, order_by: room.position)
    |> Enum.map(fn room ->
      lodging = room.nightly_rate_cents * nights

      %{
        room
        | lodging_total_cents: lodging,
          deposit_due_cents: Pricing.room_deposit(lodging, group.rate_plan),
          cash_paid_cents: Map.get(cash, room.id, 0),
          credit_paid_cents: Map.get(credit, room.id, 0)
      }
    end)
  end

  def active_rooms(group), do: Enum.filter(rooms(group), &(&1.status == :active))

  def totals(group) do
    Enum.reduce(
      active_rooms(group),
      [
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      ],
      fn room, totals ->
        Keyword.new(totals, fn {field, amount} ->
          value =
            if field == :deposit_paid_cents,
              do: room.cash_paid_cents + room.credit_paid_cents,
              else: Map.fetch!(room, field)

          {field, amount + value}
        end)
      end
    )
  end

  def allocate_cash!(group, operation, amount) do
    fill!(group, amount, fn room, cents ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room.id,
        payment_operation_id: operation.operation_id,
        amount_cents: cents,
        allocation_order: next_allocation_order()
      })
    end)
  end

  def allocate_credit!(group, operation, lot, amount) do
    fill!(group, amount, fn room, cents ->
      Repo.insert!(%Allocation{
        group_id: group.group_id,
        room_id: room.id,
        credit_lot_id: lot.id,
        operation_id: operation.operation_id,
        amount_cents: cents,
        allocation_order: next_allocation_order()
      })
    end)
  end

  @doc "Moves the newest held portions first, retaining payment and credit-lot provenance."
  def transfer!(source, destination, amount, operation) do
    room_ids = Enum.map(active_rooms(source), & &1.id)

    cash =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.room_id in ^room_ids and allocation.disposition == :held
      )

    credit =
      Repo.all(
        from allocation in Allocation,
          where: allocation.room_id in ^room_ids and allocation.status == :applied
      )

    0 =
      (cash ++ credit)
      |> Enum.sort_by(& &1.allocation_order, :desc)
      |> Enum.reduce(amount, fn allocation, remaining ->
        moved = min(allocation.amount_cents, remaining)

        if moved > 0 do
          move_portion!(allocation, destination, moved)

          if is_struct(allocation, CashAllocation) do
            Reporting.cash!(operation, source.group_id, %{transferred_out_cents: moved})
            Reporting.cash!(operation, destination.group_id, %{transferred_in_cents: moved})
          end
        end

        remaining - moved
      end)

    :ok
  end

  defp move_portion!(allocation, destination, amount) do
    # Fill before removing the source portion, so newly created allocations
    # follow every existing allocation even when moving the newest one in full.
    fill!(destination, amount, fn room, cents ->
      allocation
      |> transferred_portion()
      |> Ecto.Changeset.change(
        group_id: destination.group_id,
        room_id: room.id,
        amount_cents: cents,
        allocation_order: next_allocation_order()
      )
      |> Repo.insert!()
    end)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  defp transferred_portion(%CashAllocation{} = allocation) do
    %CashAllocation{payment_operation_id: allocation.payment_operation_id, transferred: true}
  end

  defp transferred_portion(%Allocation{} = allocation) do
    %Allocation{credit_lot_id: allocation.credit_lot_id, operation_id: allocation.operation_id}
  end

  # Operations hold SQLite's write reservation before allocating. Indexed maxima
  # therefore provide a shared, durable creation order without a process counter.
  # Historical splits retain their order; new room funding always follows them.
  defp next_allocation_order do
    cash = Repo.aggregate(CashAllocation, :max, :allocation_order) || 0
    credit = Repo.aggregate(Allocation, :max, :allocation_order) || 0
    max(cash, credit) + 1
  end

  defp fill!(group, amount, insert) do
    remaining =
      Enum.reduce(active_rooms(group), amount, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocated = min(capacity, remaining)
        if allocated > 0, do: insert.(room, allocated)
        remaining - allocated
      end)

    # Callers validate outstanding before writing. A mismatch is a storage/domain
    # invariant failure and must roll back the operation rather than lose funding.
    0 = remaining
    :ok
  end

  defp balances(schema, group_id, status_field, status) do
    Repo.all(
      from allocation in schema,
        where: allocation.group_id == ^group_id and field(allocation, ^status_field) == ^status,
        select: {allocation.room_id, allocation.amount_cents}
    )
    |> Enum.reduce(%{}, fn {room_id, amount}, totals ->
      Map.update(totals, room_id, amount, &(&1 + amount))
    end)
  end
end
