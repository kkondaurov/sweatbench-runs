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
  alias GroupStay.Accounting.{Allocation, CashPayment}
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

  @doc "Removes held cash, returning the allocation, group and amount of each drawn slice."
  def remove_cash(payment_id, amount) do
    held_allocations()
    |> where([allocation], allocation.cash_payment_id == ^payment_id)
    |> Repo.all()
    |> draw(amount)
  end

  @doc "Moves newest allocations first, creating destination allocations in draw order."
  def transfer(source_group_id, destination_group_id, amount) do
    drawn =
      held_allocations()
      |> where([_allocation, room], room.group_id == ^source_group_id)
      |> Repo.all()
      |> draw(amount)

    for {allocation, _group_id, moved} <- drawn do
      provenance = Map.take(allocation, [:cash_payment_id, :credit_lot_id])
      fund(destination_group_id, moved, provenance)
    end

    payment_ids =
      drawn
      |> Enum.map(fn {allocation, _, _} -> allocation.cash_payment_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.update_all(from(payment in CashPayment, where: payment.id in ^payment_ids),
      set: [transferred: true]
    )

    cash =
      drawn
      |> Enum.filter(fn {allocation, _, _} -> not is_nil(allocation.cash_payment_id) end)
      |> Enum.map(fn {_, _, amount} -> amount end)
      |> Enum.sum()

    {:ok, cash}
  end

  def held_cash_by_group(payment_id) do
    held_allocations()
    |> where([allocation], allocation.cash_payment_id == ^payment_id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn {allocation, group_id}, totals ->
      Map.update(totals, group_id, allocation.amount_cents, &(&1 + allocation.amount_cents))
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
  end

  defp held_allocations do
    from allocation in Allocation,
      join: room in assoc(allocation, :room),
      where: room.status == "active",
      order_by: [desc: allocation.id],
      select: {allocation, room.group_id}
  end

  # A partially drawn allocation keeps its seniority at the source. The returned
  # slices retain provenance and order; callers can refill another group or report
  # exactly which groups a payment correction changed.
  defp draw(allocations, amount) do
    {remaining, drawn} =
      Enum.reduce_while(allocations, {amount, []}, fn
        _allocation, {0, drawn} ->
          {:halt, {0, drawn}}

        {allocation, group_id}, {remaining, drawn} ->
          removed = min(allocation.amount_cents, remaining)

          if removed == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            allocation
            |> Changeset.change(amount_cents: allocation.amount_cents - removed)
            |> Repo.update!()
          end

          {:cont, {remaining - removed, [{allocation, group_id, removed} | drawn]}}
      end)

    0 = remaining
    Enum.reverse(drawn)
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
