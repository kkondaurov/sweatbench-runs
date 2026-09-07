defmodule GroupStay.Reservations.DepositTransfers do
  @moduledoc """
  Moves held deposit funding between a guest's active groups.

  Draws newest allocations first across both funding kinds, then fills the
  destination's rooms in draw order. New portions retain their payment or lot
  provenance. No cash entry, credit redemption, settlement, or expiry transition
  occurs: only the location of already applied funding changes.

  Existence and revision guards are checked by the reservations context before
  entering this module. All validation precedes writes in the same transaction.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.{Finance, Repo}

  alias GroupStay.Reservations.{
    AllocationOrder,
    CashAllocation,
    Group,
    RoomAccounting,
    RoomCreditAllocation
  }

  def transfer(source, destination, operation, occurred_on) do
    amount = operation["amount_cents"]

    with :ok <- validate(source, destination, amount) do
      drawn = source.group_id |> held_allocations() |> draw(amount)

      {source_rooms, destination_rooms} =
        Enum.reduce(drawn, {source.rooms, destination.rooms}, fn
          {allocation, moved}, {source_rooms, destination_rooms} ->
            field = funding_field(allocation)
            {destination_rooms, portions} = RoomAccounting.fund(destination_rooms, moved, field)

            Enum.each(portions, fn {room_id, cents} ->
              allocate_destination(allocation, destination.group_id, room_id, cents)
            end)

            remove_source(allocation, moved)

            if match?(%CashAllocation{}, allocation) do
              Finance.record_cash(
                source.group_id,
                operation,
                occurred_on,
                :transferred_out,
                moved
              )

              Finance.record_cash(
                destination.group_id,
                operation,
                occurred_on,
                :transferred_in,
                moved
              )
            end

            source_rooms =
              RoomAccounting.remove(source_rooms, [{allocation.room_id, moved}], field)

            {source_rooms, destination_rooms}
        end)

      {:ok, source_rooms, destination_rooms}
    end
  end

  # Validation guarantees enough held funding; only the final draw can be partial.
  defp draw(_allocations, 0), do: []

  defp draw([allocation | rest], remaining) do
    moved = min(remaining, held_amount(allocation))
    [{allocation, moved} | draw(rest, remaining - moved)]
  end

  defp validate(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, :invalid_transfer}

      source.status != :active ->
        {:error, %{code: "group_not_active", group_id: source.group_id}}

      destination.status != :active ->
        {:error, %{code: "group_not_active", group_id: destination.group_id}}

      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_amount}

      amount > source.deposit_paid_cents ->
        {:error, :transfer_exceeds_held_funding}

      amount > Group.outstanding_deposit(destination) ->
        {:error, :transfer_exceeds_outstanding}

      true ->
        :ok
    end
  end

  defp held_allocations(group_id) do
    cash = Repo.all(from a in CashAllocation, where: a.group_id == ^group_id and a.held_cents > 0)

    credit =
      Repo.all(from a in RoomCreditAllocation, where: a.group_id == ^group_id and a.active)

    Enum.sort_by(cash ++ credit, & &1.allocation_order, :desc)
  end

  defp held_amount(%CashAllocation{held_cents: amount}), do: amount
  defp held_amount(%RoomCreditAllocation{amount_cents: amount}), do: amount

  defp funding_field(%CashAllocation{}), do: :cash_paid_cents
  defp funding_field(%RoomCreditAllocation{}), do: :credit_paid_cents

  defp allocate_destination(%CashAllocation{} = source, group_id, room_id, amount) do
    AllocationOrder.insert!(%CashAllocation{
      group_id: group_id,
      room_id: room_id,
      payment_operation_id: source.payment_operation_id,
      amount_cents: amount,
      held_cents: amount,
      transferred: true
    })
  end

  defp allocate_destination(%RoomCreditAllocation{} = source, group_id, room_id, amount) do
    AllocationOrder.insert!(%RoomCreditAllocation{
      group_id: group_id,
      room_id: room_id,
      credit_lot_id: source.credit_lot_id,
      credit_allocation_id: source.credit_allocation_id,
      amount_cents: amount
    })
  end

  defp remove_source(%{amount_cents: amount} = allocation, amount), do: Repo.delete!(allocation)

  defp remove_source(%CashAllocation{} = allocation, amount) do
    Repo.update!(
      change(allocation,
        amount_cents: allocation.amount_cents - amount,
        held_cents: allocation.held_cents - amount
      )
    )
  end

  defp remove_source(%RoomCreditAllocation{} = allocation, amount) do
    Repo.update!(change(allocation, amount_cents: allocation.amount_cents - amount))
  end
end
