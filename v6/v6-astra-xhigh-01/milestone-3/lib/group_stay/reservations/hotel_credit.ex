defmodule GroupStay.Reservations.HotelCredit do
  @moduledoc """
  Tracks available lots and their allocations to active deposits. Mutations run
  inside the partner operation's immediate transaction, including any rollback.
  Expiry is evaluated at read/application time; reads never discard balances.
  """

  import Ecto.Query
  import GroupStay.Operations.Rejection, only: [reject: 1]
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot}

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
    issued = cash + div(cash * 10 + 50, 100)

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

    issued
  end

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

          {:cont, unpaid - consumed}
        end
      end)

    if unpaid > 0, do: reject("insufficient_credit")
    :ok
  end

  def settle(group, refundable, on) do
    allocations =
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id

    if refundable do
      allocations
      |> Repo.all()
      |> Repo.preload(:credit_lot)
      |> Enum.each(fn allocation ->
        lot = allocation.credit_lot

        # Redeemed credit keeps its liability while active, even past expiry.
        # Once released, an expired allocation is consumed instead of restored.
        if Date.compare(lot.expires_on, on) != :lt do
          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
          |> Repo.update!()
        end
      end)
    end

    Repo.delete_all(allocations)
  end
end
