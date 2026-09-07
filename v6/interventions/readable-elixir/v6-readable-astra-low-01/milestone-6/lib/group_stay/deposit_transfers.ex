defmodule GroupStay.DepositTransfers do
  @moduledoc """
  Moves held funding without settlement. Each destination allocation is newly
  created, retaining the payment or credit lot of the source portion. Credit stays
  redeemed throughout the move, so neither expiry nor liability changes.
  """
  alias GroupStay.{Finance, Repo, RoomAccounting, CashAllocation}
  alias GroupStay.RoomAccounting.AllocationOrder
  alias GroupStay.Reservations.Group
  alias GroupStay.Credits.Allocation

  def apply(source, destination, amount, occurred_on) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, "invalid_transfer"}

      source.status != "active" ->
        inactive(source)

      destination.status != "active" ->
        inactive(destination)

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > source.deposit_paid_cents ->
        {:error, "transfer_exceeds_held_funding"}

      amount > Group.outstanding(destination) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        move(source, destination, amount, occurred_on)
    end
  end

  defp inactive(group), do: {:error, %{code: "group_not_active", group_id: group.group_id}}

  defp move(source, destination, amount, occurred_on) do
    source.group_id
    |> AllocationOrder.held()
    |> Enum.reduce_while(amount, fn allocation, needed ->
      moved = min(needed, allocation.amount_cents)

      if moved == allocation.amount_cents do
        Repo.delete!(allocation)
      else
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - moved)
        |> Repo.update!()
      end

      if match?(%CashAllocation{}, allocation) do
        Finance.cash_transfer(source, destination, moved, occurred_on)
      end

      deposit(destination, allocation, moved)
      if moved == needed, do: {:halt, 0}, else: {:cont, needed - moved}
    end)

    source = RoomAccounting.advance_revision(source)
    destination = RoomAccounting.advance_revision(destination)

    {:ok,
     %{
       source_group_id: source.group_id,
       destination_group_id: destination.group_id,
       amount_cents: amount,
       source_outstanding_deposit_cents: Group.outstanding(source),
       destination_outstanding_deposit_cents: Group.outstanding(destination),
       source_revision: source.revision,
       destination_revision: destination.revision
     }}
  end

  defp deposit(group, %CashAllocation{payment_operation_id: id}, amount) do
    if id do
      Repo.insert_all("transferred_payments", [%{payment_operation_id: id}],
        on_conflict: :nothing
      )
    end

    RoomAccounting.fund_cash(group, id, amount)
  end

  defp deposit(group, %Allocation{lot_id: id}, amount),
    do: RoomAccounting.fund_credit(group, id, amount)
end
