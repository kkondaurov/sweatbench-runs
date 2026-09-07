defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Credit balances and deposit funding provenance.

  Mutations run inside the reservation operation's write transaction. Expiry is
  evaluated at the requested date without mutating balances during reads.
  Allocations remain liable until cancellation, regardless of their lot's expiry.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, CreditEntitlement, RoomAccounting}

  def available(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  def balance(guest_id, on) do
    lots = available(guest_id, on)

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

    applied = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    available + applied
  end

  def shortfall do
    applied_by_lot =
      from a in CreditAllocation,
        group_by: a.credit_lot_id,
        select: %{credit_lot_id: a.credit_lot_id, amount_cents: sum(a.amount_cents)}

    Repo.one(
      from l in CreditLot,
        join: a in subquery(applied_by_lot),
        on: a.credit_lot_id == l.id,
        select:
          coalesce(sum(fragment("min(?, ?)", l.unrecovered_clawback_cents, a.amount_cents)), 0)
    )
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def issue(group, operation_id, on, cash_rows) do
    cash = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    amount = bonus_value(cash)

    if amount > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id,
          remaining_cents: amount,
          expires_on: Date.add(on, 365)
        })

      # Group by payment before rounding. The first allocation identifies funding
      # order; the unattributed block is always senior to recorded payments.
      cash_rows
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.sort_by(fn {id, rows} ->
        if is_nil(id), do: -1, else: Enum.min(Enum.map(rows, & &1.allocation_order))
      end)
      |> Enum.reduce(0, fn {id, rows}, preceding ->
        through = preceding + Enum.sum(Enum.map(rows, & &1.amount_cents))

        if id do
          Repo.insert!(%CreditEntitlement{
            payment_operation_id: id,
            credit_lot_id: lot.id,
            amount_cents: bonus_value(through) - bonus_value(preceding)
          })
        end

        through
      end)
    end

    GroupStay.Finance.credit(on, "issued", amount)
    amount
  end

  def revoke_payment(id, on) do
    for entitlement <- Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)
      GroupStay.Finance.revoke_credit(on, lot.expires_on, revoked)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
      )
      |> Repo.update!()
    end
  end

  def apply(group, amount, on, operation_id) do
    lots = available(group.guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount,
      do: GroupStay.Operations.reject(%{code: "insufficient_credit"})

    Enum.reduce_while(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)
      lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used) |> Repo.update!()
      RoomAccounting.fund(group, used, :credit, operation_id, lot.id)
      if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
    end)
  end

  def settle(group, room_ids, refundable, on) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_id == ^group.group_id and a.room_id in ^room_ids
      )

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable do
        # Absorb revoked entitlement even after expiry. Only the excess may
        # return to availability, and it keeps the original lot deadline.
        absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

        restored =
          if Date.compare(lot.expires_on, on) == :lt,
            do: 0,
            else: allocation.amount_cents - absorbed

        GroupStay.Finance.credit(on, "absorbed", absorbed)
        GroupStay.Finance.credit(on, "expired", allocation.amount_cents - absorbed - restored)

        lot
        |> Ecto.Changeset.change(
          remaining_cents: lot.remaining_cents + restored,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      else
        GroupStay.Finance.credit(on, "consumed", allocation.amount_cents)
      end

      Repo.delete!(allocation)
    end
  end
end
