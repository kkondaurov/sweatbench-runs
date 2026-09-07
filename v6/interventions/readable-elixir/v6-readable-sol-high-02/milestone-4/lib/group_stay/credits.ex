defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots, room allocations, and converted-cash entitlements.

  Available credit is consumed by contractual expiry order. Applied credit is tied to a room and
  retains its original lot so refundable room cancellation can restore the promise. A chargeback
  can claw back a converted entitlement; any already-spent portion becomes a shortfall that is
  absorbed if credit later returns to that lot.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditEntitlement, CreditLot}
  alias GroupStay.Payments.CashPayment
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Room, RoomAccounting}

  def available_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)), lots: lots}
  end

  def liability_cents(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.status == :active,
          select: sum(allocation.amount_cents)
      ) || 0

    available + applied
  end

  def shortfall_cents do
    Repo.all(
      from lot in CreditLot,
        join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: lot.unrecovered_clawback_cents > 0 and room.status == :active,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select: {lot.unrecovered_clawback_cents, sum(allocation.amount_cents)}
    )
    |> Enum.reduce(0, fn {unrecovered, applied}, total ->
      total + min(unrecovered, applied || 0)
    end)
  end

  @doc "Consumes unexpired lots and allocates them across active rooms in original order."
  def apply_to_group(group, amount_cents, occurred_on, operation_id) do
    lots = available_lots(group.guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, :insufficient_credit}
    else
      rooms = RoomAccounting.active_rooms(group.group_id)
      consume(lots, rooms, amount_cents, group.group_id, operation_id)
    end
  end

  @doc "Creates a 110% lot and attributes its exact value across contributing payments."
  def issue_for_cash(group, source_operation_id, cash_cents, occurred_on, cash_allocations) do
    credit_cents = cash_cents + round_percentage(cash_cents, 10)

    lot =
      %CreditLot{}
      |> CreditLot.creation_changeset(%{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: credit_cents,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    create_entitlements(lot, cash_allocations)
    lot
  end

  @doc "Settles only credit allocated to the supplied rooms."
  def settle_rooms(rooms, refundable?, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.room_id in ^room_ids,
          order_by: allocation.id
      )

    Enum.each(allocations, fn allocation ->
      if refundable?, do: restore(allocation.credit_lot_id, allocation.amount_cents, occurred_on)
      Repo.delete!(allocation)
    end)

    :ok
  end

  def settle_group(group, refundable?, occurred_on) do
    group.group_id
    |> RoomAccounting.active_rooms()
    |> settle_rooms(refundable?, occurred_on)
  end

  @doc "Revokes every converted-credit entitlement belonging to the payment."
  def claw_back_entitlements(%CashPayment{} = payment) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where: entitlement.cash_payment_id == ^payment.id and entitlement.clawed_back == false,
        order_by: entitlement.id
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - removed

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
      )
      |> Repo.update!()

      entitlement
      |> Ecto.Changeset.change(clawed_back: true)
      |> Repo.update!()
    end)

    :ok
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp consume(_lots, _rooms, 0, _group_id, _operation_id), do: :ok

  defp consume([lot | lots], rooms, amount, group_id, operation_id) do
    consumed = min(lot.remaining_cents, amount)

    {updated, _} =
      Repo.update_all(
        from(candidate in CreditLot,
          where: candidate.id == ^lot.id and candidate.remaining_cents >= ^consumed
        ),
        inc: [remaining_cents: -consumed]
      )

    if updated == 1 do
      rooms = allocate_lot(lot.id, rooms, consumed, group_id, operation_id)
      consume(lots, rooms, amount - consumed, group_id, operation_id)
    else
      {:error, :insufficient_credit}
    end
  end

  defp allocate_lot(_lot_id, rooms, 0, _group_id, _operation_id), do: rooms

  defp allocate_lot(lot_id, [room | rooms], amount, group_id, operation_id) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    allocated = min(capacity, amount)

    updated_room =
      if allocated > 0 do
        %CreditAllocation{}
        |> CreditAllocation.changeset(%{
          group_id: group_id,
          credit_lot_id: lot_id,
          room_id: room.id,
          funding_operation_id: operation_id,
          amount_cents: allocated
        })
        |> Repo.insert!()

        RoomAccounting.fund_room(room, 0, allocated)
      else
        room
      end

    [updated_room | allocate_lot(lot_id, rooms, amount - allocated, group_id, operation_id)]
  end

  defp restore(lot_id, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount_cents)
    excess = amount_cents - absorbed
    available = if Date.after?(occurred_on, lot.expires_on), do: 0, else: excess

    lot
    |> Ecto.Changeset.change(
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + available
    )
    |> Repo.update!()
  end

  defp create_entitlements(_lot, []), do: :ok

  defp create_entitlements(lot, allocations) do
    allocations
    |> Enum.chunk_by(& &1.cash_payment_id)
    |> Enum.reduce(0, fn payment_allocations, preceding_principal ->
      principal = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))
      total_principal = preceding_principal + principal

      entitlement =
        principal + round_percentage(total_principal, 10) -
          round_percentage(preceding_principal, 10)

      %CreditEntitlement{}
      |> CreditEntitlement.creation_changeset(%{
        credit_lot_id: lot.id,
        cash_payment_id: hd(payment_allocations).cash_payment_id,
        principal_cents: principal,
        entitlement_cents: entitlement,
        clawed_back: false
      })
      |> Repo.insert!()

      total_principal
    end)

    :ok
  end

  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)
end
