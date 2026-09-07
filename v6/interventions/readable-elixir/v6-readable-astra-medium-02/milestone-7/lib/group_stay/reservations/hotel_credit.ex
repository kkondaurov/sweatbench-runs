defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Manages credit lots and the amounts redeemed into active reservations.

  Available balances are filtered by the requested date without mutating reads.
  Allocations remain liabilities regardless of expiry. Settlement removes them,
  absorbing refundable restorations into clawback first, then restoring any excess
  only when the original lot has not yet expired.
  All writes run inside the reservation operation's transaction.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Finance}
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, CreditEntitlement, RoomAccounting}

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

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def issue(group, operation_id, on, cash_allocations) do
    amount = bonus_value(Enum.sum(Enum.map(cash_allocations, & &1.amount_cents)))

    if amount > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: amount,
          expires_on: Date.add(on, 365)
        })

      # Group by funding identity, preserving the first fill position. The senior
      # legacy block has no revocable identity but still participates in rounding.
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {id, slices} ->
        {if(is_nil(id), do: 0, else: 1), Enum.min(Enum.map(slices, & &1.allocation_order))}
      end)
      |> Enum.reduce(0, fn {payment_id, slices}, preceding ->
        running = preceding + Enum.sum(Enum.map(slices, & &1.amount_cents))

        if payment_id do
          Repo.insert!(%CreditEntitlement{
            payment_operation_id: payment_id,
            credit_lot_id: lot.id,
            amount_cents: bonus_value(running) - bonus_value(preceding)
          })
        end

        running
      end)

      Finance.credit_event(on, "issued", amount)

      if not Finance.available_at_posting?(lot, on),
        do: Finance.credit_event(on, "expired", amount)

      {amount, lot.id}
    else
      {0, nil}
    end
  end

  def shortfall do
    Repo.all(
      from lot in CreditLot,
        left_join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        where: lot.unrecovered_clawback_cents > 0,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select:
          fragment(
            "MIN(?, COALESCE(SUM(?), 0))",
            lot.unrecovered_clawback_cents,
            allocation.amount_cents
          )
    )
    |> Enum.sum()
  end

  def revoke(payment_id, on) do
    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment_id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      if Finance.available_at_posting?(lot, on),
        do: Finance.credit_event(on, "revoked", removed)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
      |> Repo.update!()
    end
  end

  def apply(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      {rooms, 0} =
        Enum.reduce(lots, {group.rooms, amount}, fn lot, {rooms, outstanding} ->
          used = min(lot.remaining_cents, outstanding)

          if used > 0 do
            if not Finance.available_at_posting?(lot, on),
              do: Finance.credit_event(on, "expired", -used)

            lot
            |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
            |> Repo.update!()
          end

          {RoomAccounting.credit(group, rooms, lot.id, used), outstanding - used}
        end)

      {:ok, rooms}
    end
  end

  def settle(group, room_ids, refundable?, on) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable? do
        absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

        restored =
          if Date.compare(lot.expires_on, on) != :lt,
            do: allocation.amount_cents - absorbed,
            else: 0

        Finance.credit_event(on, "absorbed", absorbed)
        available = if Finance.available_at_posting?(lot, on), do: restored, else: 0
        Finance.credit_event(on, "expired", allocation.amount_cents - absorbed - available)

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + restored,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      else
        Finance.credit_event(on, "consumed", allocation.amount_cents)
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
