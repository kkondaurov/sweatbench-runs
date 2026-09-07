defmodule GroupStay.HotelCredit do
  @moduledoc """
  Manages credit lots, room allocations, and chargeback clawbacks.

  Credit applied to a room pauses expiry. A refundable settlement first uses returning credit to
  extinguish any unrecovered clawback on its lot; only the excess becomes available again.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditLotEntitlement,
    HotelCreditAllocation,
    HotelCreditLot,
    Room
  }

  @doc "Issues a cancellation lot and records each durable payment's rounded entitlement."
  def issue(guest_id, source_operation_id, cash_blocks, cancelled_on) do
    principal = Enum.sum_by(cash_blocks, &elem(&1, 1))
    value = bonus_value(principal)

    if value == 0 do
      0
    else
      lot =
        %HotelCreditLot{}
        |> Changeset.change(%{
          guest_id: guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: value,
          expires_on: Date.add(cancelled_on, 365)
        })
        |> Repo.insert!()

      cash_blocks
      |> Enum.reduce(0, fn {payment_id, amount}, preceding ->
        through = preceding + amount

        if payment_id do
          %CreditLotEntitlement{}
          |> Changeset.change(%{
            lot_id: lot.id,
            payment_accounting_id: payment_id,
            principal_cents: amount,
            entitlement_cents: bonus_value(through) - bonus_value(preceding)
          })
          |> Repo.insert!()
        end

        through
      end)

      value
    end
  end

  @doc "Consumes available lots and fills active rooms in their original order."
  def allocate(guest_id, group_id, amount_cents, occurred_on) do
    lots =
      from(lot in HotelCreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      allocate_across_rooms_and_lots(available_rooms(group_id), lots, amount_cents)
      :ok
    end
  end

  @doc "Settles credit allocated to selected rooms."
  def settle_room_allocations(room_ids, refundable?, cancelled_on) do
    allocations =
      from(allocation in HotelCreditAllocation,
        where: allocation.room_id in ^room_ids,
        order_by: [asc: allocation.id],
        preload: [:lot]
      )
      |> Repo.all()

    if refundable? do
      allocations
      |> Enum.group_by(& &1.lot)
      |> Enum.each(fn {lot, entries} ->
        restore_to_lot(lot, Enum.sum_by(entries, & &1.amount_cents), cancelled_on)
      end)
    end

    from(allocation in HotelCreditAllocation, where: allocation.room_id in ^room_ids)
    |> Repo.delete_all()

    :ok
  end

  @doc "Revokes all entitlements belonging to a charged-back payment."
  def revoke_payment_entitlements(payment_accounting_id) do
    from(entitlement in CreditLotEntitlement,
      where: entitlement.payment_accounting_id == ^payment_accounting_id,
      preload: [:lot]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      removable = min(entitlement.entitlement_cents, entitlement.lot.remaining_cents)
      unrecovered = entitlement.entitlement_cents - removable

      from(lot in HotelCreditLot, where: lot.id == ^entitlement.lot_id)
      |> Repo.update_all(
        inc: [remaining_cents: -removable, unrecovered_clawback_cents: unrecovered]
      )
    end)
  end

  defp available_rooms(group_id) do
    from(room in Room,
      where: room.group_id == ^group_id and room.status == "active",
      where: room.cash_paid_cents + room.credit_paid_cents < room.deposit_due_cents,
      order_by: [asc: room.position]
    )
    |> Repo.all()
  end

  defp allocate_across_rooms_and_lots(_rooms, _lots, 0), do: :ok

  defp allocate_across_rooms_and_lots([room | rooms], lots, left) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    room_amount = min(capacity, left)
    {remaining_lots, _} = allocate_room_from_lots(room, lots, room_amount)

    from(candidate in Room, where: candidate.id == ^room.id)
    |> Repo.update_all(inc: [credit_paid_cents: room_amount])

    allocate_across_rooms_and_lots(rooms, remaining_lots, left - room_amount)
  end

  defp allocate_room_from_lots(room, [lot | lots], amount) do
    used = min(lot.remaining_cents, amount)

    from(candidate in HotelCreditLot, where: candidate.id == ^lot.id)
    |> Repo.update_all(inc: [remaining_cents: -used])

    %HotelCreditAllocation{}
    |> Changeset.change(%{
      lot_id: lot.id,
      group_id: room.group_id,
      room_id: room.id,
      amount_cents: used
    })
    |> Repo.insert!()

    lot = %{lot | remaining_cents: lot.remaining_cents - used}
    lots = if lot.remaining_cents == 0, do: lots, else: [lot | lots]

    if used == amount,
      do: {lots, 0},
      else: allocate_room_from_lots(room, lots, amount - used)
  end

  defp restore_to_lot(lot, amount, cancelled_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    restored = amount - absorbed
    available = if Date.after?(cancelled_on, lot.expires_on), do: 0, else: restored

    from(candidate in HotelCreditLot, where: candidate.id == ^lot.id)
    |> Repo.update_all(inc: [remaining_cents: available, unrecovered_clawback_cents: -absorbed])
  end

  defp bonus_value(cash_cents), do: cash_cents + div(cash_cents * 10 + 50, 100)
end
