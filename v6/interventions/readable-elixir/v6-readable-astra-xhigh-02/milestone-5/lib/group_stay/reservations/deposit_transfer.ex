defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Moves held deposit between active reservations for the same guest.

  A transfer only relocates allocations: cash keeps its payment identity and
  credit remains redeemed from its original lot, with expiry paused. Both group
  revisions and the durable result commit in the caller's operation transaction.
  """
  alias GroupStay.Accounting
  alias GroupStay.Reservations.Group

  def apply(source, destination, amount) do
    with :ok <- validate(source, destination, amount) do
      Accounting.transfer(source.group_id, destination.group_id, amount)
    end
  end

  defp validate(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, :invalid_transfer}

      source.status != "active" ->
        {:error, %{code: :group_not_active, group_id: source.group_id}}

      destination.status != "active" ->
        {:error, %{code: :group_not_active, group_id: destination.group_id}}

      not is_integer(amount) or amount <= 0 ->
        {:error, :invalid_amount}

      amount > source.deposit_paid_cents ->
        {:error, :transfer_exceeds_held_funding}

      amount > Group.outstanding_deposit_cents(destination) ->
        {:error, :transfer_exceeds_outstanding}

      true ->
        :ok
    end
  end
end
