defmodule GroupStay.Accounting do
  @moduledoc """
  Allocates funding to active rooms in original room order.

  Allocations are the source of truth for held cash and applied credit. Group
  totals are refreshed after mutations in the same operation transaction. Room
  prices remain available as booking history after cancellation; group totals
  include only active rooms.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Accounting.Allocation
  alias GroupStay.Repo
  alias GroupStay.Reservations.Room

  def rooms(group_id) do
    from(room in Room, where: room.group_id == ^group_id, order_by: room.position)
    |> Repo.all()
    |> Repo.preload(:allocations)
    |> Enum.map(fn room ->
      {cash, credit} =
        Enum.reduce(room.allocations, {0, 0}, fn allocation, {cash, credit} ->
          if allocation.cash_payment_id,
            do: {cash + allocation.amount_cents, credit},
            else: {cash, credit + allocation.amount_cents}
        end)

      %{room | cash_paid_cents: cash, credit_paid_cents: credit}
    end)
  end

  def fund(group_id, amount, source) do
    remaining =
      group_id
      |> rooms()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.reduce(amount, fn room, remaining ->
        due = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocated = min(due, remaining)

        if allocated > 0 do
          %Allocation{room_id: room.id, amount_cents: allocated}
          |> Changeset.change(source)
          |> Repo.insert!()
        end

        remaining - allocated
      end)

    # Callers validate outstanding deposits before changing any funding source.
    0 = remaining
    :ok
  end

  def remove_cash(payment_id, amount) do
    allocations =
      Repo.all(
        from allocation in Allocation,
          where: allocation.cash_payment_id == ^payment_id,
          order_by: [desc: allocation.id]
      )

    remaining =
      Enum.reduce(allocations, amount, fn allocation, remaining ->
        removed = min(allocation.amount_cents, remaining)

        cond do
          removed == 0 ->
            :ok

          removed == allocation.amount_cents ->
            Repo.delete!(allocation)

          true ->
            allocation
            |> Changeset.change(amount_cents: allocation.amount_cents - removed)
            |> Repo.update!()
        end

        remaining - removed
      end)

    0 = remaining
    :ok
  end

  def cancel(rooms) do
    room_ids = Enum.map(rooms, & &1.id)
    Repo.delete_all(from allocation in Allocation, where: allocation.room_id in ^room_ids)
    Repo.update_all(from(room in Room, where: room.id in ^room_ids), set: [status: "cancelled"])
    :ok
  end

  def group_totals(group_id) do
    active_rooms = Enum.filter(rooms(group_id), &(&1.status == "active"))
    sum = fn field -> Enum.sum(Enum.map(active_rooms, &Map.fetch!(&1, field))) end
    credit = sum.(:credit_paid_cents)

    %{
      status: if(active_rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: sum.(:lodging_total_cents),
      deposit_due_cents: sum.(:deposit_due_cents),
      deposit_paid_cents: sum.(:cash_paid_cents) + credit,
      credit_paid_cents: credit
    }
  end

  def applied_credit_by_lot do
    from(allocation in Allocation,
      where: not is_nil(allocation.credit_lot_id),
      select: {allocation.credit_lot_id, allocation.amount_cents}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {lot_id, amount}, totals ->
      Map.update(totals, lot_id, amount, &(&1 + amount))
    end)
  end
end
