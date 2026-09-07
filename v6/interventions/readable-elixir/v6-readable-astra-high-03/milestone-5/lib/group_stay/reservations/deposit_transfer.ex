defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Moves held deposit between a guest's active groups. Each source slice is drawn
  newest first and filled into the destination before drawing the next slice.
  New slices record their new allocation order while retaining payment or lot
  identity. Credit remains redeemed throughout; no settlement occurs here.

  Runs inside the durable operation transaction, after both revision guards.
  """
  alias GroupStay.{Credit, Payments}
  alias GroupStay.Reservations.{Group, RoomAccounting}

  def apply(source, destination, amount) do
    with :ok <- validate(source, destination, amount) do
      0 =
        source
        |> RoomAccounting.held()
        |> Enum.reverse()
        |> Enum.reduce(amount, fn slice, remaining ->
          moved = min(slice.amount_cents, remaining)
          if moved > 0, do: move(slice, destination, moved)
          remaining - moved
        end)

      groups = RoomAccounting.refresh_groups([source.group_id, destination.group_id])
      source = Map.fetch!(groups, source.group_id)
      destination = Map.fetch!(groups, destination.group_id)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount,
         source_outstanding_deposit_cents: Group.outstanding_deposit(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp validate(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, "invalid_transfer"}

      source.status != "active" ->
        {:error, %{code: "group_not_active", group_id: source.group_id}}

      destination.status != "active" ->
        {:error, %{code: "group_not_active", group_id: destination.group_id}}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > source.deposit_paid_cents ->
        {:error, "transfer_exceeds_held_funding"}

      amount > Group.outstanding_deposit(destination) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp move(slice, destination, amount) do
    RoomAccounting.remove(slice, amount)

    RoomAccounting.fund(destination, amount, %{
      payment_operation_id: slice.payment_operation_id,
      credit_lot_id: slice.credit_lot_id
    })

    cond do
      slice.credit_lot_id ->
        Credit.transfer(slice.group_id, destination.group_id, slice.credit_lot_id, amount)

      slice.payment_operation_id ->
        Payments.mark_transferred(slice.payment_operation_id)

      true ->
        :ok
    end
  end
end
