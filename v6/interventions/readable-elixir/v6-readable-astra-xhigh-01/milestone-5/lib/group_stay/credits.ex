defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots, room funding, and payment-created entitlements.

  Mutations share the reservation operation's immediate transaction. Reads apply
  expiry without mutating lots: `on` evaluates stored balances at that expiry
  date, rather than reconstructing a historical ledger. Applied credit remains
  a liability even after expiry or a chargeback of its originating cash.
  """

  import Ecto.Query

  alias GroupStay.Credits.{Allocation, Entitlement, Lot}
  alias GroupStay.Repo
  alias GroupStay.Reservations.RoomAccounting

  @doc "Returns a guest's available credit and lots in redemption order."
  def balance(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  @doc "Includes unexpired available credit and all credit funding active deposits."
  def liability_cents(on) do
    available =
      Repo.all(from lot in Lot, where: lot.expires_on >= ^on, select: lot.remaining_cents)

    Enum.sum(available) + Enum.sum(Map.values(applied_by_lot()))
  end

  @doc "Caps each lot's unrecovered clawback by the credit still funding active rooms."
  def shortfall_cents do
    applied = applied_by_lot()

    Repo.all(from lot in Lot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, sum ->
      sum + min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))
    end)
  end

  @doc false
  def issue(_group, [], _operation, _occurred_on), do: {:ok, nil}

  def issue(group, cash_allocations, operation, occurred_on) do
    if Date.diff(~D[9999-12-31], occurred_on) < 365 do
      {:error, "invalid_operation"}
    else
      cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
      issued = bonus_value(cash)

      lot =
        Repo.insert!(%Lot{
          guest_id: group.guest_id,
          source_group_id: group.group_id,
          source_operation_id: operation.operation_id,
          issued_cents: issued,
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 365)
        })

      create_entitlements!(lot, cash_allocations)
      {:ok, lot}
    end
  end

  @doc false
  def apply_to_group(group, operation, amount, occurred_on) do
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      allocate!(lots, group, operation, amount)
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  @doc false
  def settle!(rooms, refundable?, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from allocation in Allocation,
        where: allocation.room_id in ^room_ids and allocation.status == :applied,
        order_by: allocation.id
    )
    |> Enum.each(fn allocation ->
      if refundable? do
        restore!(allocation, occurred_on)
      else
        allocation |> Ecto.Changeset.change(status: :consumed) |> Repo.update!()
      end
    end)
  end

  @doc false
  def revoke_entitlements!(payment_operation_id) do
    Repo.all(
      from entitlement in Entitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        order_by: entitlement.id
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
      )
      |> Repo.update!()
    end)
  end

  defp create_entitlements!(lot, allocations) do
    # Group a payment's selected room portions before rounding. The first portion
    # orders payments by funding, with the imported senior block always first.
    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {payment_id, portions} ->
      {if(is_nil(payment_id), do: 0, else: 1),
       Enum.min(Enum.map(portions, & &1.allocation_order))}
    end)
    |> Enum.reduce(0, fn {payment_id, portions}, preceding_cash ->
      through_payment = preceding_cash + Enum.sum(Enum.map(portions, & &1.amount_cents))

      Repo.insert!(%Entitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        amount_cents: bonus_value(through_payment) - bonus_value(preceding_cash)
      })

      through_payment
    end)
  end

  defp bonus_value(cash), do: cash + div(cash + 5, 10)

  defp restore!(allocation, occurred_on) do
    # Fetch each time: several rooms and operations may have used this same lot.
    lot = Repo.get!(Lot, allocation.credit_lot_id)
    absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
    excess = allocation.amount_cents - absorbed
    status = if Date.compare(lot.expires_on, occurred_on) == :lt, do: :expired, else: :restored

    lot
    |> Ecto.Changeset.change(
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + if(status == :restored, do: excess, else: 0)
    )
    |> Repo.update!()

    cond do
      absorbed == 0 ->
        allocation |> Ecto.Changeset.change(status: status) |> Repo.update!()

      excess == 0 ->
        allocation |> Ecto.Changeset.change(status: :absorbed) |> Repo.update!()

      true ->
        allocation
        |> Ecto.Changeset.change(status: :absorbed, amount_cents: absorbed)
        |> Repo.update!()

        Repo.insert!(%Allocation{
          group_id: allocation.group_id,
          room_id: allocation.room_id,
          credit_lot_id: allocation.credit_lot_id,
          operation_id: allocation.operation_id,
          allocation_order: allocation.allocation_order,
          amount_cents: excess,
          status: status
        })
    end
  end

  defp applied_by_lot do
    Repo.all(
      from allocation in Allocation,
        where: allocation.status == :applied,
        select: {allocation.credit_lot_id, allocation.amount_cents}
    )
    |> Enum.reduce(%{}, fn {lot_id, amount}, totals ->
      Map.update(totals, lot_id, amount, &(&1 + amount))
    end)
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate!(_lots, _group, _operation, 0), do: :ok

  defp allocate!([lot | rest], group, operation, remaining) do
    amount = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount)
    |> Repo.update!()

    RoomAccounting.allocate_credit!(group, operation, lot, amount)
    allocate!(rest, group, operation, remaining - amount)
  end
end
