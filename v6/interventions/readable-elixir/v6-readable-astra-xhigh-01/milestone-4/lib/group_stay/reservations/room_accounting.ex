defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Prices rooms and allocates new funding to active deposits in original room order.

  Room prices remain available after cancellation; current funding counts only
  held cash and applied credit. Group balance columns cache sums of active rooms
  and are refreshed in the same transaction as each accounting mutation.
  """

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Finance.CashAllocation
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
        amount_cents: cents
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
        amount_cents: cents
      })
    end)
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
