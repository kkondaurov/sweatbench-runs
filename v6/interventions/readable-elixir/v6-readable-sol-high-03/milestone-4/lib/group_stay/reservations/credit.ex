defmodule GroupStay.Reservations.Credit do
  @moduledoc """
  Owns hotel-credit lots, their room allocations, and cash-funded entitlement.

  Available credit uses earliest-expiry-first consumption. Applied credit keeps
  its original lot identity while expiry is paused. A payment chargeback can
  therefore revoke unspent entitlement immediately and track only the portion
  that is temporarily tied up in another active reservation.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Room,
    RoomAccounting
  }

  @doc "Issues 110% of converted cash and records its funding-source slices."
  def issue(guest_id, source_operation_id, contributions, cancelled_on) do
    cash_cents = Enum.sum_by(contributions, & &1.amount_cents)
    issued_cents = bonus_value(cash_cents)

    if issued_cents > 0 do
      lot =
        %CreditLot{}
        |> CreditLot.creation_changeset(%{
          guest_id: guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: issued_cents,
          # Credit is usable through day 365 and unavailable the following day.
          expires_on: Date.add(cancelled_on, 366)
        })
        |> Repo.insert!()

      create_entitlements(lot, contributions)
    end

    issued_cents
  end

  @doc "Allocates unexpired lots across active rooms in room-fill order."
  def apply(%Group{} = group, amount_cents, occurred_on, funding_operation_id) do
    lots = available_lots_query(group.guest_id, occurred_on) |> Repo.all()

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      allocate(
        RoomAccounting.active_rooms(group.group_id),
        lots,
        group.group_id,
        funding_operation_id,
        amount_cents
      )

      :ok
    end
  end

  @doc "Restores selected room allocations, absorbing outstanding clawback first."
  def restore_allocations(room_ids, cancelled_on) do
    allocations = allocations_for_rooms(room_ids)

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      lot = Repo.get!(CreditLot, lot_id)
      restored_cents = Enum.sum_by(lot_allocations, & &1.amount_cents)
      absorbed_cents = min(restored_cents, lot.unrecovered_clawback_cents)
      excess_cents = restored_cents - absorbed_cents

      available_cents =
        if available_on?(lot, cancelled_on),
          do: lot.remaining_cents + excess_cents,
          else: lot.remaining_cents

      lot
      |> CreditLot.clawback_changeset(
        available_cents,
        lot.unrecovered_clawback_cents - absorbed_cents
      )
      |> Repo.update!()
    end)

    remove_allocations(allocations)
    :ok
  end

  @doc "Permanently consumes credit assigned to selected non-refundable rooms."
  def consume_allocations(room_ids) do
    room_ids
    |> allocations_for_rooms()
    |> remove_allocations()

    :ok
  end

  @doc "Revokes every credit entitlement created from a charged-back payment."
  def revoke_entitlements(cash_funding_id) do
    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          where:
            entitlement.cash_funding_id == ^cash_funding_id and
              entitlement.revoked == false,
          order_by: entitlement.id
      )

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed_cents = min(lot.remaining_cents, entitlement.entitlement_cents)

      lot
      |> CreditLot.clawback_changeset(
        lot.remaining_cents - removed_cents,
        lot.unrecovered_clawback_cents + entitlement.entitlement_cents - removed_cents
      )
      |> Repo.update!()

      entitlement
      |> Ecto.Changeset.change(revoked: true)
      |> Repo.update!()
    end)

    :ok
  end

  @doc "Creates telescoping entitlement slices for an existing issued lot."
  def create_entitlements(%CreditLot{} = lot, contributions) do
    contributions
    |> Enum.sort_by(& &1.cash_funding.funding_order)
    |> Enum.reduce(0, fn contribution, preceding_principal ->
      running_principal = preceding_principal + contribution.amount_cents
      entitlement_cents = bonus_value(running_principal) - bonus_value(preceding_principal)

      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        credit_lot_id: lot.id,
        cash_funding_id: contribution.cash_funding.id,
        principal_cents: contribution.amount_cents,
        entitlement_cents: entitlement_cents,
        revoked: false
      })
      |> Repo.insert!()

      running_principal
    end)

    :ok
  end

  @doc "Returns a guest's available, unexpired lots in redemption order."
  def available_credit(guest_id, on) do
    lots = available_lots_query(guest_id, on) |> Repo.all()
    %{guest_id: guest_id, available_cents: Enum.sum_by(lots, & &1.remaining_cents), lots: lots}
  end

  @doc "Returns available plus active-room-allocated credit as of a date."
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
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  @doc "Returns the current credit tied up despite an unrecovered clawback."
  def shortfall_cents do
    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.sum_by(fn lot ->
      allocated =
        Repo.one(
          from allocation in CreditAllocation,
            join: room in Room,
            on: room.id == allocation.room_id,
            where: allocation.credit_lot_id == ^lot.id and room.status == "active",
            select: coalesce(sum(allocation.amount_cents), 0)
        )

      min(lot.unrecovered_clawback_cents, allocated)
    end)
  end

  defp available_lots_query(guest_id, on) do
    from lot in CreditLot,
      where:
        lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
          lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate(_rooms, _lots, _group_id, _operation_id, 0), do: :ok

  defp allocate([], _lots, _group_id, _operation_id, remaining_cents) do
    raise "credit funding exceeds active room capacity by #{remaining_cents} cents"
  end

  defp allocate(_rooms, [], _group_id, _operation_id, remaining_cents) do
    raise "credit funding exceeds available lots by #{remaining_cents} cents"
  end

  defp allocate([room | rooms], [lot | lots], group_id, operation_id, remaining_cents) do
    room_capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    allocated_cents = min(remaining_cents, min(room_capacity, lot.remaining_cents))

    if allocated_cents == 0 do
      cond do
        room_capacity == 0 ->
          allocate(rooms, [lot | lots], group_id, operation_id, remaining_cents)

        lot.remaining_cents == 0 ->
          allocate([room | rooms], lots, group_id, operation_id, remaining_cents)
      end
    else
      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        credit_lot_id: lot.id,
        group_id: group_id,
        room_id: room.id,
        funding_operation_id: operation_id,
        amount_cents: allocated_cents
      })
      |> Repo.insert!()

      updated_lot =
        lot
        |> CreditLot.balance_changeset(lot.remaining_cents - allocated_cents)
        |> Repo.update!()

      updated_room =
        room
        |> Room.accounting_changeset(%{
          credit_paid_cents: room.credit_paid_cents + allocated_cents
        })
        |> Repo.update!()

      allocate(
        [updated_room | rooms],
        [updated_lot | lots],
        group_id,
        operation_id,
        remaining_cents - allocated_cents
      )
    end
  end

  defp allocations_for_rooms(room_ids) do
    Repo.all(
      from allocation in CreditAllocation,
        where: allocation.room_id in ^room_ids,
        join: room in assoc(allocation, :room),
        preload: [room: room]
    )
  end

  defp remove_allocations(allocations) do
    allocations
    |> Enum.group_by(& &1.room_id)
    |> Enum.each(fn {_room_id, room_allocations} ->
      room = hd(room_allocations).room
      removed_cents = Enum.sum_by(room_allocations, & &1.amount_cents)

      room
      |> Room.accounting_changeset(%{credit_paid_cents: room.credit_paid_cents - removed_cents})
      |> Repo.update!()
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp bonus_value(principal_cents),
    do: principal_cents + div(principal_cents * 10 + 50, 100)

  defp available_on?(lot, on), do: Date.compare(lot.expires_on, on) == :gt
end
