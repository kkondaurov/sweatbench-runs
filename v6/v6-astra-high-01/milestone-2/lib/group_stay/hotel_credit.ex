defmodule GroupStay.HotelCredit do
  @moduledoc false
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{CreditAllocation, CreditLot, Repo}

  def available(guest_id, on) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def available_liability(on) do
    Repo.all(from l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents)
    |> Enum.sum()
  end

  # All mutations run within the reservation operation's IMMEDIATE transaction.
  def issue(group, operation_id, date) do
    amount = group.cash_paid_cents + div(group.cash_paid_cents * 10 + 50, 100)

    if amount > 9_223_372_036_854_775_807,
      do: Repo.rollback(%{code: "invalid_amount"})

    if amount > 0 do
      expires_on = Date.add(date, 365)
      if expires_on.year > 9999, do: Repo.rollback(%{code: "invalid_operation"})

      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: expires_on
      })
    end

    amount
  end

  def apply(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount,
      do: Repo.rollback(%{code: "insufficient_credit"})

    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      change_remaining(lot, -used)

      allocation =
        Repo.get_by(CreditAllocation, group_id: group.group_id, credit_lot_id: lot.id)

      if allocation do
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents + used)
        |> Repo.update!()
      else
        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })
      end

      if needed == used, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  def settle(group, refundable, on) do
    allocations = from a in CreditAllocation, where: a.group_id == ^group.group_id

    if refundable do
      for allocation <- Repo.all(allocations) do
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)

        # An expired restoration is consumed immediately. Reads never mutate lots,
        # so a future-dated read cannot affect a subsequent operation's expiry check.
        if Date.compare(lot.expires_on, on) != :lt,
          do: change_remaining(lot, allocation.amount_cents)
      end
    end

    Repo.delete_all(allocations)
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  defp change_remaining(lot, delta) do
    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + delta)
    |> Repo.update!()
  end
end
