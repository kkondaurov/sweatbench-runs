defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Relocates held allocations without settlement. A moved slice receives a new
  allocation order at its destination, while the source remainder keeps its age.
  Payment and lot identities survive every move. The caller owns the transaction
  and checks both groups' existence and revision guards before calling this module.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.HotelCredit.Allocation
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Reservations.{Group, RoomAccounting}

  def apply(source, destination, op) do
    amount = op["amount_cents"]

    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, "invalid_transfer"}

      source.status != "active" ->
        {:error, "group_not_active", %{group_id: source.group_id}}

      destination.status != "active" ->
        {:error, "group_not_active", %{group_id: destination.group_id}}

      not Map.has_key?(op, "amount_cents") ->
        {:error, "invalid_operation"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > source.deposit_paid_cents ->
        {:error, "transfer_exceeds_held_funding"}

      amount > Group.outstanding(destination) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        move(source, destination, amount)
    end
  end

  defp move(source, destination, amount) do
    cash =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^source.group_id and a.disposition == "held"
      )

    credit = Repo.all(from a in Allocation, where: a.group_id == ^source.group_id)
    slices = Enum.sort_by(cash ++ credit, & &1.allocation_order, :desc)

    {0, source_rooms, destination_rooms} =
      Enum.reduce(slices, {amount, source.rooms, destination.rooms}, fn slice,
                                                                        {remaining, source_rooms,
                                                                         destination_rooms} ->
        used = min(remaining, slice.amount_cents)

        if used == 0 do
          {remaining, source_rooms, destination_rooms}
        else
          remove_slice(slice, used)
          remember_payment(slice)
          source_rooms = remove_room_funding(source_rooms, slice, used)
          destination_rooms = fill_destination(destination, destination_rooms, slice, used)

          {remaining - used, source_rooms, destination_rooms}
        end
      end)

    for {group, rooms} <- [{source, source_rooms}, {destination, destination_rooms}] do
      changes = Map.put(RoomAccounting.totals(rooms), :revision, group.revision + 1)
      Repo.update!(Ecto.Changeset.change(group, changes))
    end

    {:ok,
     %{
       source_group_id: source.group_id,
       destination_group_id: destination.group_id,
       amount_cents: amount,
       source_outstanding_deposit_cents: Group.outstanding(source) + amount,
       destination_outstanding_deposit_cents: Group.outstanding(destination) - amount,
       source_revision: source.revision + 1,
       destination_revision: destination.revision + 1
     }}
  end

  defp remove_slice(slice, used) do
    if used == slice.amount_cents,
      do: Repo.delete!(slice),
      else: Repo.update!(Ecto.Changeset.change(slice, amount_cents: slice.amount_cents - used))
  end

  defp remember_payment(%CashAllocation{payment_operation_id: id}) when not is_nil(id) do
    Repo.insert_all("transferred_payments", [%{payment_operation_id: id}], on_conflict: :nothing)
  end

  defp remember_payment(_slice), do: :ok

  defp remove_room_funding(rooms, slice, used) do
    field = if funding_kind(slice) == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

    Enum.map(rooms, fn room ->
      if room["room_id"] == slice.room_id,
        do: Map.update!(room, field, &(&1 - used)),
        else: room
    end)
  end

  defp fill_destination(destination, rooms, slice, amount) do
    RoomAccounting.fund(rooms, amount, funding_kind(slice), fn room_id, cents ->
      # Only provenance is copied. The new row gets its own creation order.
      allocation =
        case slice do
          %CashAllocation{} -> %CashAllocation{payment_operation_id: slice.payment_operation_id}
          %Allocation{} -> %Allocation{credit_lot_id: slice.credit_lot_id}
        end

      Repo.insert!(%{
        allocation
        | group_id: destination.group_id,
          room_id: room_id,
          amount_cents: cents
      })
    end)
  end

  defp funding_kind(%CashAllocation{}), do: :cash
  defp funding_kind(%Allocation{}), do: :credit
end
