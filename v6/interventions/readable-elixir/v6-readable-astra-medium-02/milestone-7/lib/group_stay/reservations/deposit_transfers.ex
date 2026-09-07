defmodule GroupStay.Reservations.DepositTransfers do
  @moduledoc """
  Moves held deposit slices without settlement. Destination slices receive new
  allocation positions while retaining their payment or credit-lot provenance.
  Validation and both group updates share the operation journal transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation, Group, RoomAccounting}

  def transfer(source, destination, amount, on) do
    with :ok <- validate(source, destination, amount) do
      {source_rooms, destination_rooms, 0} =
        Enum.reduce(held(source.group_id), {source.rooms, destination.rooms, amount}, fn
          allocation, {source_rooms, destination_rooms, remaining} ->
            used = min(allocation.amount_cents, remaining)

            if used == 0 do
              {source_rooms, destination_rooms, remaining}
            else
              if match?(%CashAllocation{}, allocation),
                do: GroupStay.Finance.transfer_cash(source, destination, used, on)

              kind = funding_field(allocation)
              withdraw(allocation, used)
              remember_payment(allocation)

              source_rooms =
                Enum.map(source_rooms, fn room ->
                  if room.room_id == allocation.room_id,
                    do: Map.update!(room, kind, &(&1 - used)),
                    else: room
                end)

              destination_rooms = deposit(destination, destination_rooms, allocation, used)

              {source_rooms, destination_rooms, remaining - used}
            end
        end)

      {:ok, RoomAccounting.changes(source_rooms), RoomAccounting.changes(destination_rooms)}
    end
  end

  defp validate(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, "invalid_transfer"}

      source.status != "active" ->
        {:error, "group_not_active", %{group_id: source.group_id}}

      destination.status != "active" ->
        {:error, "group_not_active", %{group_id: destination.group_id}}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > source.deposit_paid_cents ->
        {:error, "transfer_exceeds_held_funding"}

      amount > Group.outstanding(destination) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp held(group_id) do
    cash =
      Repo.all(
        from a in CashAllocation, where: a.group_id == ^group_id and a.disposition == "held"
      )

    credit = Repo.all(from a in CreditAllocation, where: a.group_id == ^group_id)
    Enum.sort_by(cash ++ credit, & &1.allocation_order, :desc)
  end

  defp deposit(group, rooms, %CashAllocation{payment_operation_id: payment_id}, amount),
    do: RoomAccounting.cash(%{group | rooms: rooms}, payment_id, amount)

  defp deposit(group, rooms, %CreditAllocation{credit_lot_id: lot_id}, amount),
    do: RoomAccounting.credit(group, rooms, lot_id, amount)

  defp funding_field(%CashAllocation{}), do: :cash_paid_cents
  defp funding_field(%CreditAllocation{}), do: :credit_paid_cents

  defp withdraw(allocation, amount) when allocation.amount_cents == amount,
    do: Repo.delete!(allocation)

  defp withdraw(allocation, amount) do
    allocation
    |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
    |> Repo.update!()
  end

  defp remember_payment(%CashAllocation{payment_operation_id: id}) when not is_nil(id) do
    Repo.insert_all("transferred_payments", [%{payment_operation_id: id}], on_conflict: :nothing)
  end

  defp remember_payment(_), do: :ok
end
