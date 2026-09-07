defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Moves held deposit allocations between active group reservations.

  The caller validates the groups and amount. This module performs the atomic
  accounting move: it draws the newest cash or credit allocation first, keeps
  every piece's payment or lot provenance, and appends those pieces to the
  destination while filling its rooms in their original order.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditAllocation
  alias GroupStay.Payments.{CashAllocation, CashPayment}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room, RoomAccounting}

  @doc "Moves an already validated amount and returns refreshed groups."
  def move!(%Group{} = source, %Group{} = destination, amount_cents) do
    next_order = RoomAccounting.next_allocation_order()
    {pieces, transferred_payment_ids} = draw_pieces(source, amount_cents)

    {_rooms, _next_order} =
      Enum.reduce(
        pieces,
        {RoomAccounting.active_rooms(destination), next_order},
        fn piece, {rooms, allocation_order} ->
          place_piece(piece, destination, rooms, allocation_order)
        end
      )

    mark_payments_transferred!(transferred_payment_ids)

    {RoomAccounting.refresh_group!(source), RoomAccounting.refresh_group!(destination)}
  end

  defp draw_pieces(source, amount_cents) do
    entries = cash_entries(source) ++ credit_entries(source)

    {amount_left, pieces, payment_ids} =
      entries
      |> Enum.sort_by(& &1.allocation_order, :desc)
      |> Enum.reduce_while({amount_cents, [], MapSet.new()}, fn entry,
                                                                {amount_left, pieces, payment_ids} ->
        if amount_left == 0 do
          {:halt, {amount_left, pieces, payment_ids}}
        else
          moved = min(entry.allocation.amount_cents, amount_left)
          shrink_or_delete!(entry.allocation, moved)
          decrement_room!(entry.kind, entry.allocation.room_record_id, moved)

          payment_ids = remember_payment(payment_ids, entry)
          {:cont, {amount_left - moved, [piece(entry, moved) | pieces], payment_ids}}
        end
      end)

    if amount_left != 0, do: raise("validated transfer exceeded source funding")
    {Enum.reverse(pieces), payment_ids}
  end

  defp cash_entries(source) do
    CashAllocation
    |> where([allocation], allocation.group_record_id == ^source.id)
    |> Repo.all()
    |> Enum.map(&%{kind: :cash, allocation: &1, allocation_order: &1.allocation_order})
  end

  defp credit_entries(source) do
    CreditAllocation
    |> where([allocation], allocation.group_record_id == ^source.id)
    |> Repo.all()
    |> Enum.map(&%{kind: :credit, allocation: &1, allocation_order: &1.allocation_order})
  end

  defp remember_payment(payment_ids, %{kind: :cash, allocation: allocation})
       when not is_nil(allocation.cash_payment_id) do
    MapSet.put(payment_ids, allocation.cash_payment_id)
  end

  defp remember_payment(payment_ids, _entry), do: payment_ids

  defp piece(%{kind: :cash, allocation: allocation}, amount) do
    %{
      kind: :cash,
      cash_payment_id: allocation.cash_payment_id,
      funding_order: allocation.funding_order,
      amount_cents: amount
    }
  end

  defp piece(%{kind: :credit, allocation: allocation}, amount) do
    %{
      kind: :credit,
      credit_lot_id: allocation.credit_lot_id,
      funding_operation_id: allocation.funding_operation_id,
      funding_order: allocation.funding_order,
      amount_cents: amount
    }
  end

  defp place_piece(%{amount_cents: 0}, _destination, rooms, allocation_order),
    do: {rooms, allocation_order}

  defp place_piece(piece, destination, [room | rooms], allocation_order) do
    capacity = room_capacity(room)

    if capacity == 0 do
      {rooms, allocation_order} = place_piece(piece, destination, rooms, allocation_order)
      {[room | rooms], allocation_order}
    else
      amount = min(piece.amount_cents, capacity)
      insert_allocation!(piece, destination.id, room.id, allocation_order, amount)
      room = increment_room!(room, piece.kind, amount)
      piece = %{piece | amount_cents: piece.amount_cents - amount}

      if piece.amount_cents == 0 do
        {[room | rooms], allocation_order + 1}
      else
        {rooms, allocation_order} =
          place_piece(piece, destination, rooms, allocation_order + 1)

        {[room | rooms], allocation_order}
      end
    end
  end

  defp place_piece(%{amount_cents: amount}, _destination, [], _allocation_order)
       when amount > 0 do
    raise "validated transfer exceeded destination capacity"
  end

  defp insert_allocation!(%{kind: :cash} = piece, group_id, room_id, order, amount) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      group_record_id: group_id,
      room_record_id: room_id,
      cash_payment_id: piece.cash_payment_id,
      funding_order: piece.funding_order,
      allocation_order: order,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp insert_allocation!(%{kind: :credit} = piece, group_id, room_id, order, amount) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: piece.credit_lot_id,
      group_record_id: group_id,
      room_record_id: room_id,
      funding_operation_id: piece.funding_operation_id,
      funding_order: piece.funding_order,
      allocation_order: order,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp shrink_or_delete!(allocation, removed) do
    remaining = allocation.amount_cents - removed

    if remaining == 0 do
      Repo.delete!(allocation)
    else
      changeset =
        case allocation do
          %CashAllocation{} ->
            CashAllocation.changeset(allocation, %{amount_cents: remaining})

          %CreditAllocation{} ->
            CreditAllocation.changeset(allocation, %{amount_cents: remaining})
        end

      Repo.update!(changeset)
    end
  end

  defp decrement_room!(kind, room_id, amount) do
    field = paid_field(kind)

    {1, _} =
      Room
      |> where([room], room.id == ^room_id)
      |> Repo.update_all(inc: [{field, -amount}])
  end

  defp increment_room!(room, kind, amount) do
    field = paid_field(kind)

    room
    |> Room.changeset(%{field => Map.fetch!(room, field) + amount})
    |> Repo.update!()
  end

  defp room_capacity(room) do
    max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
  end

  defp paid_field(:cash), do: :cash_paid_cents
  defp paid_field(:credit), do: :credit_paid_cents

  defp mark_payments_transferred!(payment_ids) do
    if MapSet.size(payment_ids) > 0 do
      CashPayment
      |> where([payment], payment.id in ^MapSet.to_list(payment_ids))
      |> Repo.update_all(set: [transfer_participated: true])
    end
  end
end
