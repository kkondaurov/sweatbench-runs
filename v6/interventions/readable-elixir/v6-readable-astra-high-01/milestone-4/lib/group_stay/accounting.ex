defmodule GroupStay.Accounting do
  @moduledoc """
  Room deposit allocation and cash disposition accounting.

  Funding fills active rooms in booking order. Allocations are never shuffled
  after settlement or a correction: subsequent funding fills the newly open
  capacity. All writes belong to the enclosing durable operation transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credits.Allocation

  @dispositions ~w(held refunded retained converted_to_credit reduced charged_back)
  def dispositions, do: @dispositions

  def cash(group_id) do
    Repo.all(from a in CashAllocation, where: a.group_id == ^group_id, order_by: a.id)
  end

  def credit(group_id) do
    Repo.all(from a in Allocation, where: a.group_id == ^group_id, order_by: a.id)
  end

  def fund_cash(group, payment_id, amount) do
    allocate(group, amount, fn room_id, cents ->
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: cents
      })
    end)
  end

  def fund_credit(group, lot_id, amount) do
    allocate(group, amount, fn room_id, cents ->
      Repo.insert!(%Allocation{
        group_id: group.group_id,
        room_id: room_id,
        credit_lot_id: lot_id,
        amount_cents: cents
      })
    end)
  end

  defp allocate(group, amount, insert) do
    rooms = rooms(group)

    remaining =
      Enum.reduce(rooms, amount, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        cents = if room.status == "active", do: min(remaining, capacity), else: 0
        if cents > 0, do: insert.(room.room_id, cents)
        remaining - cents
      end)

    if remaining != 0, do: raise("funding exceeds room capacity")
    :ok
  end

  defp rooms(group) do
    cash = Enum.filter(cash(group.group_id), &(&1.disposition == "held"))
    credit = credit(group.group_id)

    Enum.map(group.rooms, fn room ->
      %{
        room
        | cash_paid_cents: total_for_room(cash, room.room_id),
          credit_paid_cents: total_for_room(credit, room.room_id)
      }
    end)
  end

  defp total_for_room(allocations, room_id) do
    allocations |> Enum.filter(&(&1.room_id == room_id)) |> sum()
  end

  @doc "Persists the current deposit view and advances its revision exactly once."
  def refresh(group, cancelled_room_ids \\ []) do
    rooms =
      Enum.map(rooms(group), fn room ->
        if room.room_id in cancelled_room_ids,
          do: %{room | status: "cancelled", lodging_total_cents: 0, deposit_due_cents: 0},
          else: room
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))
    cash = cash(group.group_id)
    cash_paid = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    changes =
      [
        revision: group.revision + 1,
        status: if(active == [], do: "cancelled", else: "active"),
        lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
        deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
        cash_paid_cents: cash_paid,
        credit_paid_cents: credit_paid,
        deposit_paid_cents: cash_paid + credit_paid
      ] ++
        Enum.map(Enum.drop(@dispositions, 1), fn disposition ->
          {String.to_existing_atom("cash_#{disposition}_cents"),
           cash |> Enum.filter(&(&1.disposition == disposition)) |> sum()}
        end)

    group
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.put_embed(:rooms, rooms)
    |> Repo.update!()
  end

  def move(allocation, amount, disposition) do
    if amount == allocation.amount_cents do
      allocation |> Ecto.Changeset.change(disposition: disposition) |> Repo.update!()
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()

      Repo.insert!(%CashAllocation{
        group_id: allocation.group_id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: amount,
        disposition: disposition
      })
    end
  end

  def remove_held(allocations, amount, disposition) do
    Enum.reduce(Enum.reverse(allocations), amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)
      if removed > 0, do: move(allocation, removed, disposition)
      remaining - removed
    end)
  end

  def sum(allocations), do: Enum.sum(Enum.map(allocations, & &1.amount_cents))
end
