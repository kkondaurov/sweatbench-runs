defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Manages credit lots and the amounts redeemed into active reservations.

  Available balances are filtered by the requested date without mutating reads.
  Allocations remain liabilities regardless of expiry. Settlement removes them,
  restoring refundable amounts only when the original lot has not yet expired.
  All writes run inside the reservation operation's transaction.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot}

  def balance(guest_id, on) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    redeemed = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    available + redeemed
  end

  def issue(group, operation_id, on) do
    cash = group.cash_paid_cents
    amount = cash + div(cash * 10 + 50, 100)

    if amount > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: Date.add(on, 365)
      })
    end

    amount
  end

  def apply(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      Enum.reduce_while(lots, amount, fn lot, outstanding ->
        used = min(lot.remaining_cents, outstanding)

        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })

        if used == outstanding, do: {:halt, 0}, else: {:cont, outstanding - used}
      end)

      :ok
    end
  end

  def settle(group, refundable?, on) do
    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable? and Date.compare(lot.expires_on, on) != :lt do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end

    :ok
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end
end
