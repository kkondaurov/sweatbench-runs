defmodule GroupStay.DepositTransfers do
  @moduledoc """
  Moves held deposit funding between active groups without changing its accounting identity.

  Cash remains attached to its original payment and hotel credit remains attached to its original
  lot. Only the active room holding each allocation changes. New shared allocation-order entries
  record the exact order in which transferred units fill the destination, allowing later transfers
  and provider corrections to unwind funding consistently.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditAllocation
  alias GroupStay.Funding.AllocationOrder
  alias GroupStay.Payments.{CashAllocation, CashPayment}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Room, RoomAccounting}

  @type drawn_allocation ::
          %{kind: :cash, cash_payment_id: pos_integer(), amount_cents: pos_integer()}
          | %{
              kind: :credit,
              credit_lot_id: pos_integer(),
              funding_operation_id: String.t() | nil,
              amount_cents: pos_integer()
            }

  @doc "Returns all cash and credit currently held on a group's active rooms."
  @spec held_cents(String.t()) :: non_neg_integer()
  def held_cents(group_id) do
    group_id
    |> held_allocations()
    |> Enum.reduce(0, fn entry, total -> total + entry.allocation.amount_cents end)
  end

  @doc "Moves an already-validated amount between the two groups."
  @spec transfer(String.t(), String.t(), pos_integer()) :: %{cash_cents: non_neg_integer()}
  def transfer(source_group_id, destination_group_id, amount_cents) do
    drawn = draw(held_allocations(source_group_id), amount_cents, [])
    place(drawn, RoomAccounting.active_rooms(destination_group_id), destination_group_id)

    cash_cents =
      drawn
      |> Enum.filter(&(&1.kind == :cash))
      |> Enum.reduce(0, fn allocation, total -> total + allocation.amount_cents end)

    %{cash_cents: cash_cents}
  end

  defp held_allocations(group_id) do
    cash =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where:
            room.group_id == ^group_id and room.status == :active and
              allocation.disposition == :held,
          select: %{kind: :cash, allocation: allocation}
      )

    credit =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id and room.status == :active,
          select: %{kind: :credit, allocation: allocation}
      )

    Enum.sort_by(cash ++ credit, & &1.allocation.allocation_order_id, :desc)
  end

  defp draw(_allocations, 0, drawn), do: Enum.reverse(drawn)

  defp draw([entry | allocations], remaining, drawn) do
    amount = min(entry.allocation.amount_cents, remaining)
    remove_from_source(entry, amount)
    draw(allocations, remaining - amount, [provenance(entry, amount) | drawn])
  end

  defp remove_from_source(%{kind: kind, allocation: allocation}, amount) do
    room = Repo.get!(Room, allocation.room_id)
    {cash_delta, credit_delta} = if kind == :cash, do: {-amount, 0}, else: {0, -amount}
    RoomAccounting.fund_room(room, cash_delta, credit_delta)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end

    if kind == :cash do
      Repo.update_all(
        from(payment in CashPayment, where: payment.id == ^allocation.cash_payment_id),
        set: [transfer_participated: true]
      )
    end
  end

  defp provenance(%{kind: :cash, allocation: allocation}, amount) do
    %{kind: :cash, cash_payment_id: allocation.cash_payment_id, amount_cents: amount}
  end

  defp provenance(%{kind: :credit, allocation: allocation}, amount) do
    %{
      kind: :credit,
      credit_lot_id: allocation.credit_lot_id,
      funding_operation_id: allocation.funding_operation_id,
      amount_cents: amount
    }
  end

  defp place([], _rooms, _group_id), do: :ok

  defp place([allocation | allocations], rooms, group_id) do
    {rooms, remaining} = place_allocation(allocation, rooms, group_id)

    if remaining == 0 do
      place(allocations, rooms, group_id)
    else
      raise "validated transfer exceeded destination room capacity"
    end
  end

  defp place_allocation(allocation, [room | rooms], group_id) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    amount = min(capacity, allocation.amount_cents)

    if amount == 0 do
      {rooms, remaining} = place_allocation(allocation, rooms, group_id)
      {[room | rooms], remaining}
    else
      create_destination_allocation(allocation, room.id, group_id, amount)

      updated_room =
        case allocation.kind do
          :cash -> RoomAccounting.fund_room(room, amount, 0)
          :credit -> RoomAccounting.fund_room(room, 0, amount)
        end

      remaining = allocation.amount_cents - amount

      if remaining == 0 do
        {[updated_room | rooms], 0}
      else
        rest = %{allocation | amount_cents: remaining}
        {rooms, remaining} = place_allocation(rest, rooms, group_id)
        {[updated_room | rooms], remaining}
      end
    end
  end

  defp place_allocation(allocation, [], _group_id), do: {[], allocation.amount_cents}

  defp create_destination_allocation(%{kind: :cash} = allocation, room_id, _group_id, amount) do
    %CashAllocation{}
    |> CashAllocation.creation_changeset(%{
      cash_payment_id: allocation.cash_payment_id,
      room_id: room_id,
      amount_cents: amount,
      disposition: :held,
      allocation_order_id: AllocationOrder.next_id!()
    })
    |> Repo.insert!()
  end

  defp create_destination_allocation(allocation, room_id, group_id, amount) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      group_id: group_id,
      credit_lot_id: allocation.credit_lot_id,
      room_id: room_id,
      funding_operation_id: allocation.funding_operation_id,
      amount_cents: amount,
      allocation_order_id: AllocationOrder.next_id!()
    })
    |> Repo.insert!()
  end
end
