defmodule GroupStay.Reservations.DepositTransfers do
  @moduledoc """
  Moves held deposit slices between active reservations for the same guest.

  Allocation IDs define creation order across cash and credit. Draw newest first,
  inserting fresh destination slices in draw order while retaining their provenance.
  The unmoved portion of a source slice keeps its original place in that order.
  All validation precedes writes inside the durable operation transaction.
  """
  import Ecto.Changeset, only: [change: 2]

  alias GroupStay.{FinanceReporting, Repo}
  alias GroupStay.Reservations.{Group, HotelCredit, RoomAccounting}

  def transfer(source, destination, amount, reporting) do
    with :ok <- validate(source, destination, amount) do
      0 =
        source
        |> RoomAccounting.rooms()
        |> Enum.filter(&(&1.status == :active))
        |> Enum.flat_map(& &1.allocations)
        |> Enum.filter(&(&1.disposition == "held"))
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.reduce_while(amount, fn allocation, needed ->
          used = min(needed, allocation.amount_cents)

          RoomAccounting.allocate(destination, used,
            payment_operation_id: allocation.payment_operation_id,
            credit_lot_id: allocation.credit_lot_id,
            transferred: true
          )

          if allocation.credit_lot_id do
            HotelCredit.transfer(source, destination, allocation.credit_lot_id, used)
          else
            FinanceReporting.cash(reporting, source.property_id, "transferred_out_cents", used)

            FinanceReporting.cash(
              reporting,
              destination.property_id,
              "transferred_in_cents",
              used
            )
          end

          if used == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            allocation |> change(amount_cents: allocation.amount_cents - used) |> Repo.update!()
          end

          if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
        end)

      source = refresh(source)
      destination = refresh(destination)

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

      source.status != :active ->
        {:error, "group_not_active", %{group_id: source.group_id}}

      destination.status != :active ->
        {:error, "group_not_active", %{group_id: destination.group_id}}

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

  defp refresh(group) do
    group
    |> RoomAccounting.refresh()
    |> change(revision: group.revision + 1)
    |> Repo.update!()
  end
end
