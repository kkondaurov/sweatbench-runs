defmodule GroupStay.Credits do
  @moduledoc """
  Hotel credit balances and the provenance of redeemed deposits.

  Available credit expires by calendar date; allocations remain liabilities
  regardless of expiry until settled. Reads project expiry without mutating
  balances. The `on` date is an expiry cutoff, not a historical account snapshot.
  Mutations run inside the reservation operation's write transaction.
  """
  import Ecto.Query
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Repo

  def for_guest(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.all(from lot in Lot, where: lot.expires_on >= ^on, select: lot.remaining_cents)

    allocated = Repo.all(from allocation in Allocation, select: allocation.amount_cents)
    Enum.sum(available) + Enum.sum(allocated)
  end

  def issue(group, source_operation_id, occurred_on) do
    cash = group.cash_paid_cents
    # Round the 10% bonus independently, nearest cent with exact halves upward.
    amount = cash + div(cash + 5, 10)

    if amount > 0 do
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    amount
  end

  def apply_to_group(group, amount, occurred_on) do
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, needed ->
        redeemed = min(lot.remaining_cents, needed)
        change_remaining(lot, -redeemed)

        Repo.insert!(%Allocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: redeemed
        })

        if needed == redeemed, do: {:halt, 0}, else: {:cont, needed - redeemed}
      end)

      :ok
    end
  end

  def settle(group, refundable?, occurred_on) do
    allocations =
      Repo.all(from allocation in Allocation, where: allocation.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(Lot, allocation.credit_lot_id)

      if refundable? and Date.compare(lot.expires_on, occurred_on) != :lt do
        change_remaining(lot, allocation.amount_cents)
      end

      # Non-refundable redemptions and already-expired restorations are consumed.
      Repo.delete!(allocation)
    end

    :ok
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.expires_on >= ^on and lot.remaining_cents > 0,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp change_remaining(lot, delta) do
    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + delta)
    |> Repo.update!()
  end
end
