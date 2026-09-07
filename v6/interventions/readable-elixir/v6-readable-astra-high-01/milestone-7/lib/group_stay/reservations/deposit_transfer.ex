defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Relocates held funding without settlement, repricing, or credit expiry checks.

  Source slices are drawn newest first across both funding kinds. Each slice
  fills destination rooms before the next is drawn, retaining payment or lot
  provenance. Both reservation views commit with the durable transfer receipt.
  """
  alias GroupStay.{Accounting, Payments, Repo}
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credits.Allocation
  alias GroupStay.Reservations.Group

  def apply(source, destination, operation) do
    with :ok <- validate(source, destination, operation) do
      allocations =
        (Enum.filter(Accounting.cash(source.group_id), &(&1.disposition == "held")) ++
           Accounting.credit(source.group_id))
        |> Enum.sort_by(& &1.allocation_order, :desc)

      Enum.reduce_while(allocations, operation["amount_cents"], fn allocation, remaining ->
        moved = min(allocation.amount_cents, remaining)
        withdraw(allocation, moved)
        deposit(destination, allocation, moved)

        if moved == remaining, do: {:halt, 0}, else: {:cont, remaining - moved}
      end)

      source = Accounting.refresh(source)
      destination = Accounting.refresh(destination)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: operation["amount_cents"],
         source_outstanding_deposit_cents: Group.outstanding_deposit(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp validate(source, destination, operation) do
    amount = operation["amount_cents"]

    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject("invalid_transfer")

      source.status != "active" ->
        {:error, %{code: "group_not_active", group_id: source.group_id}}

      destination.status != "active" ->
        {:error, %{code: "group_not_active", group_id: destination.group_id}}

      not Map.has_key?(operation, "amount_cents") ->
        reject("invalid_operation")

      not is_integer(amount) or amount <= 0 ->
        reject("invalid_amount")

      amount > source.deposit_paid_cents ->
        reject("transfer_exceeds_held_funding")

      amount > Group.outstanding_deposit(destination) ->
        reject("transfer_exceeds_outstanding")

      true ->
        :ok
    end
  end

  defp withdraw(allocation, amount) when amount == allocation.amount_cents,
    do: Repo.delete!(allocation)

  defp withdraw(allocation, amount) do
    allocation
    |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
    |> Repo.update!()
  end

  defp deposit(group, %CashAllocation{} = allocation, amount) do
    Payments.mark_transferred(allocation.payment_operation_id)
    Accounting.fund_cash(group, allocation.payment_operation_id, amount)
  end

  defp deposit(group, %Allocation{} = allocation, amount),
    do: Accounting.fund_credit(group, allocation.credit_lot_id, amount)

  defp reject(code), do: {:error, %{code: code}}
end
