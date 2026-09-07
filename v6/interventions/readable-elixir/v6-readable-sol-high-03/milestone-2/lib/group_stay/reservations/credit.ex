defmodule GroupStay.Reservations.Credit do
  @moduledoc """
  Owns the lifecycle of hotel-credit lots and their reservation allocations.

  Available credit uses earliest-expiry-first consumption. Allocating a lot
  moves value out of its available balance while retaining the source link;
  thus allocated value remains a liability even after the lot's normal expiry.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group}

  @doc "Issues 110% of converted cash and returns the resulting credit amount."
  def issue(guest_id, source_operation_id, cash_cents, cancelled_on) do
    issued_cents = cash_cents + rounded_percentage(cash_cents, 10)

    if issued_cents > 0 do
      attributes = %{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: issued_cents,
        # Credit is usable through day 365 and unavailable the following day.
        expires_on: Date.add(cancelled_on, 366)
      }

      %CreditLot{}
      |> CreditLot.creation_changeset(attributes)
      |> Repo.insert!()
    end

    issued_cents
  end

  @doc "Allocates unexpired lots to a group in the contractually defined order."
  def apply(%Group{} = group, amount_cents, occurred_on) do
    lots = available_lots_query(group.guest_id, occurred_on) |> Repo.all()

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      allocate(lots, group.group_id, amount_cents)
      :ok
    end
  end

  @doc "Restores a group's allocations when their original lots remain unexpired."
  def restore_allocations(group_id, cancelled_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group_id,
          join: lot in assoc(allocation, :credit_lot),
          preload: [credit_lot: lot]
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_allocations} ->
      lot = hd(lot_allocations).credit_lot
      restored_cents = Enum.sum_by(lot_allocations, & &1.amount_cents)

      if available_on?(lot, cancelled_on) do
        lot
        |> CreditLot.balance_changeset(lot.remaining_cents + restored_cents)
        |> Repo.update!()
      end
    end)

    Repo.delete_all(from allocation in CreditAllocation, where: allocation.group_id == ^group_id)
    :ok
  end

  @doc "Permanently consumes credit allocated to a non-refundable group."
  def consume_allocations(group_id) do
    Repo.delete_all(from allocation in CreditAllocation, where: allocation.group_id == ^group_id)
    :ok
  end

  @doc "Returns a guest's available, unexpired lots in redemption order."
  def available_credit(guest_id, on) do
    lots = available_lots_query(guest_id, on) |> Repo.all()
    %{guest_id: guest_id, available_cents: Enum.sum_by(lots, & &1.remaining_cents), lots: lots}
  end

  @doc "Returns available plus active-group-allocated credit as of a date."
  def liability_cents(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp available_lots_query(guest_id, on) do
    from lot in CreditLot,
      where:
        lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
          lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate(_lots, _group_id, 0), do: :ok

  defp allocate([lot | remaining_lots], group_id, amount_cents) do
    allocated_cents = min(lot.remaining_cents, amount_cents)

    lot
    |> CreditLot.balance_changeset(lot.remaining_cents - allocated_cents)
    |> Repo.update!()

    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: lot.id,
      group_id: group_id,
      amount_cents: allocated_cents
    })
    |> Repo.insert!()

    allocate(remaining_lots, group_id, amount_cents - allocated_cents)
  end

  defp rounded_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp available_on?(lot, on), do: Date.compare(lot.expires_on, on) == :gt
end
