defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Manages guest credit lots and their allocation to deposits.

  Mutations run inside the reservation operation's immediate transaction. Credit is
  checked in full before consuming any lots. Allocations keep original lot provenance
  and pause expiry; refundable settlement restores only amounts still valid on the
  cancellation date. Expired restorations and non-refundable allocations are consumed.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [change: 2, put_change: 3]

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CancellationPolicy, CreditAllocation, CreditLot, Group}

  def balance(guest_id, on) do
    lots =
      guest_id
      |> available_lots(on)
      |> Enum.map(&Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  @doc "Available liability; the ledger separately includes credit funding active groups."
  def available_liability(on) do
    Repo.one(
      from lot in CreditLot,
        where: lot.expires_on >= ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
    )
  end

  def apply_to_group(group, amount, occurred_on) do
    with {:ok, changeset, result} <- Group.pay(group, amount) do
      lots = available_lots(group.guest_id, occurred_on)

      if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
        {:error, "insufficient_credit"}
      else
        allocate(group, lots, amount)
        {:ok, put_change(changeset, :credit_paid_cents, group.credit_paid_cents + amount), result}
      end
    end
  end

  def settle(group, occurred_on, source_operation_id, issued_cents) do
    if CancellationPolicy.refundable?(group, occurred_on) do
      restore(group, occurred_on)
    end

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )

    if issued_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        expires_on: Date.add(occurred_on, 365),
        remaining_cents: issued_cents
      })
    end

    :ok
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.expires_on >= ^on and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp allocate(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      lot |> change(remaining_cents: lot.remaining_cents - used) |> Repo.update!()

      case Repo.get_by(CreditAllocation, group_id: group.group_id, credit_lot_id: lot.id) do
        nil ->
          Repo.insert!(%CreditAllocation{
            group_id: group.group_id,
            credit_lot_id: lot.id,
            amount_cents: used
          })

        allocation ->
          allocation |> change(amount_cents: allocation.amount_cents + used) |> Repo.update!()
      end

      if needed == used, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  defp restore(group, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: lot in assoc(allocation, :credit_lot),
          where: allocation.group_id == ^group.group_id and lot.expires_on >= ^occurred_on,
          preload: [credit_lot: lot]
      )

    Enum.each(allocations, fn allocation ->
      lot = allocation.credit_lot

      lot
      |> change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
      |> Repo.update!()
    end)
  end
end
