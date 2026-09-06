defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Tracks available lots and their allocations to active deposits. Mutations run
  inside the partner operation's immediate transaction, including any rollback.
  Expiry is evaluated at read/application time; reads never discard balances.
  """

  import Ecto.Query
  import GroupStay.Operations.Rejection, only: [reject: 1]
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, RoomAccounting}

  def available_query(on) do
    from lot in CreditLot,
      where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  def guest_credit(guest_id, on) do
    lots =
      on
      |> available_query()
      |> where([lot], lot.guest_id == ^guest_id)
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def issue(group, source_operation_id, cash, on) do
    issued = bonus_value(cash)

    lot =
      if issued > 0 do
        expires_on = Date.add(on, 365)
        if expires_on.year > 9999, do: reject("invalid_operation")

        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: issued,
          expires_on: expires_on
        })
      end

    {issued, lot}
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def apply_to_group(group, amount, on) do
    lots =
      on
      |> available_query()
      |> where([lot], lot.guest_id == ^group.guest_id)
      |> Repo.all()

    unpaid =
      Enum.reduce_while(lots, amount, fn lot, unpaid ->
        if unpaid == 0 do
          {:halt, 0}
        else
          consumed = min(lot.remaining_cents, unpaid)

          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed)
          |> Repo.update!()

          case Repo.get_by(CreditAllocation, group_id: group.group_id, credit_lot_id: lot.id) do
            nil ->
              Repo.insert!(%CreditAllocation{
                group_id: group.group_id,
                credit_lot_id: lot.id,
                amount_cents: consumed
              })

            allocation ->
              allocation
              |> Ecto.Changeset.change(amount_cents: allocation.amount_cents + consumed)
              |> Repo.update!()
          end

          RoomAccounting.fund(group.group_id, consumed, %{credit_lot_id: lot.id})
          {:cont, unpaid - consumed}
        end
      end)

    if unpaid > 0, do: reject("insufficient_credit")
    :ok
  end

  def settle_amount(group_id, lot_id, amount, refundable, on) do
    allocation = Repo.get_by!(CreditAllocation, group_id: group_id, credit_lot_id: lot_id)

    if refundable do
      lot = Repo.get!(CreditLot, lot_id)
      absorbed = min(amount, lot.unrecovered_clawback_cents)
      restored = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: amount - absorbed

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents + restored,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
      |> Repo.update!()
    end

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  def claw_back(lot_id, entitlement) do
    lot = Repo.get!(CreditLot, lot_id)
    removed = min(lot.remaining_cents, entitlement)

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents - removed,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - removed
    )
    |> Repo.update!()
  end

  def shortfall do
    from(a in CreditAllocation,
      join: lot in CreditLot,
      on: lot.id == a.credit_lot_id,
      where: lot.unrecovered_clawback_cents > 0,
      order_by: lot.id,
      select: {lot.id, lot.unrecovered_clawback_cents, a.amount_cents}
    )
    |> Repo.stream()
    |> Stream.chunk_by(fn {id, _clawback, _amount} -> id end)
    |> Enum.reduce(0, fn [{_id, clawback, _amount} | _] = allocations, total ->
      applied = Enum.sum(Enum.map(allocations, fn {_id, _clawback, amount} -> amount end))
      total + min(clawback, applied)
    end)
  end
end
