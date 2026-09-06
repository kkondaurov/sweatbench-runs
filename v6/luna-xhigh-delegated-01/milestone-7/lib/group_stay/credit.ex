defmodule GroupStay.Credit do
  @moduledoc "Hotel-credit lots and the allocations that pause their expiry."

  import Ecto.Query

  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
  alias GroupStay.Groups.{Group, RoomAllocation}
  alias GroupStay.Repo

  @active_status "active"

  def read_guest(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def available_lots(guest_id, as_of) do
    Repo.all(
      from lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  def consume(guest_id, group_id, amount_cents, as_of) do
    lots = available_lots(guest_id, as_of)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      {:ok, consume_lots(lots, group_id, amount_cents, [])}
    end
  end

  def settle_allocations(group_id, as_of, refundable?) do
    room_allocations =
      Repo.all(
        from allocation in RoomAllocation,
          where: allocation.group_id == ^group_id and allocation.funding_type == "credit",
          order_by: [asc: allocation.id]
      )

    settle_room_allocations(room_allocations, as_of, refundable?)
  end

  def settle_room_allocations(room_allocations, as_of, refundable?) do
    {:ok, details} = settle_room_allocations_with_details(room_allocations, as_of, refundable?)

    {:ok, Enum.reduce(details, 0, &(&1.expired_cents + &1.consumed_cents + &2))}
  end

  def settle_room_allocations_with_details(room_allocations, as_of, refundable?) do
    details =
      Enum.map(room_allocations, fn room_allocation ->
        amount = room_allocation.amount_cents
        lot = Repo.get!(Lot, room_allocation.lot_id)
        Repo.delete!(room_allocation)
        remove_group_allocation(room_allocation.credit_allocation_id, amount)

        if refundable? do
          {restored_cents, absorbed_cents, expired_cents} =
            restore_lot_detailed(lot.id, amount, as_of)

          %{
            lot_id: lot.id,
            expires_on: lot.expires_on,
            restored_cents: restored_cents,
            absorbed_cents: absorbed_cents,
            expired_cents: expired_cents,
            consumed_cents: 0
          }
        else
          %{
            lot_id: lot.id,
            expires_on: lot.expires_on,
            restored_cents: 0,
            absorbed_cents: 0,
            expired_cents: 0,
            consumed_cents: amount
          }
        end
      end)

    {:ok, details}
  end

  def allocations_for_group(group_id) do
    Repo.all(
      from allocation in Allocation,
        join: lot in Lot,
        on: lot.id == allocation.lot_id,
        where: allocation.group_id == ^group_id,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id],
        select: {allocation, lot}
    )
  end

  def issue(guest_id, source_operation_id, amount_cents, expires_on) when amount_cents > 0 do
    issue_with_contributions(guest_id, source_operation_id, amount_cents, expires_on, [])
  end

  def issue_with_contributions(
        guest_id,
        source_operation_id,
        amount_cents,
        expires_on,
        contributions
      )
      when amount_cents > 0 do
    lot =
      Repo.insert!(%Lot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount_cents,
        expires_on: expires_on,
        unrecovered_clawback_cents: 0
      })

    Enum.each(contributions, fn contribution ->
      Repo.insert!(%Entitlement{
        lot_id: lot.id,
        payment_operation_id: contribution.payment_operation_id,
        amount_cents: contribution.amount_cents
      })
    end)

    lot
  end

  def liability(as_of) do
    available =
      Repo.all(
        from lot in Lot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    applied =
      Repo.all(
        from allocation in Allocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == ^@active_status,
          select: allocation.amount_cents
      )
      |> Enum.sum()

    available + applied
  end

  def shortfall do
    Enum.reduce(Repo.all(Lot), 0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in Allocation,
            join: group in Group,
            on: group.group_id == allocation.group_id,
            where: allocation.lot_id == ^lot.id and group.status == ^@active_status,
            select: sum(allocation.amount_cents)
        ) || 0

      total + min(lot.unrecovered_clawback_cents || 0, applied)
    end)
  end

  def liability_after_cancellation(group_id, as_of, refundable?, credit_issued_cents) do
    allocations =
      Repo.all(
        from allocation in RoomAllocation,
          where: allocation.group_id == ^group_id and allocation.funding_type == "credit"
      )

    liability_after_room_settlement(allocations, as_of, refundable?, credit_issued_cents)
  end

  def liability_after_room_settlement(room_allocations, as_of, refundable?, credit_issued_cents) do
    expired_or_consumed_cents =
      Enum.reduce(room_allocations, 0, fn room_allocation, total ->
        lot = Repo.get!(Lot, room_allocation.lot_id)
        can_restore? = refundable? and Date.compare(lot.expires_on, as_of) == :gt
        if can_restore?, do: total, else: total + room_allocation.amount_cents
      end)

    liability(as_of) - expired_or_consumed_cents + credit_issued_cents
  end

  def restore_lot(lot_id, amount_cents, as_of) do
    {_restored_cents, _absorbed_cents, expired_cents} =
      restore_lot_detailed(lot_id, amount_cents, as_of)

    expired_cents
  end

  defp restore_lot_detailed(lot_id, amount_cents, as_of) do
    lot = Repo.get!(Lot, lot_id)
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered, amount_cents)
    remaining_to_restore = amount_cents - absorbed
    attrs = [unrecovered_clawback_cents: unrecovered - absorbed]

    attrs =
      if remaining_to_restore > 0 and Date.compare(lot.expires_on, as_of) == :gt do
        Keyword.put(attrs, :remaining_cents, lot.remaining_cents + remaining_to_restore)
      else
        attrs
      end

    Repo.update!(Ecto.Changeset.change(lot, attrs))

    expired =
      if remaining_to_restore > 0 and Date.compare(lot.expires_on, as_of) != :gt,
        do: remaining_to_restore,
        else: 0

    {remaining_to_restore - expired, absorbed, expired}
  end

  def claw_back_payment(payment_operation_id) do
    entitlements =
      Repo.all(
        from entitlement in Entitlement,
          where: entitlement.payment_operation_id == ^payment_operation_id,
          order_by: [asc: entitlement.id]
      )

    Enum.map(entitlements, fn entitlement ->
      lot = Repo.get!(Lot, entitlement.lot_id)
      amount = entitlement.amount_cents
      removed = min(lot.remaining_cents, amount)
      unrecovered = (lot.unrecovered_clawback_cents || 0) + amount - removed

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: unrecovered
        )
      )

      %{lot_id: lot.id, expires_on: lot.expires_on, removed_cents: removed}
    end)
  end

  def applied_for_lot(lot_id) do
    Repo.one(
      from allocation in Allocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: allocation.lot_id == ^lot_id and group.status == ^@active_status,
        select: sum(allocation.amount_cents)
    ) || 0
  end

  defp consume_lots(_lots, _group_id, 0, consumed), do: Enum.reverse(consumed)

  defp consume_lots([lot | rest], group_id, amount_cents, consumed) do
    consumed_cents = min(lot.remaining_cents, amount_cents)

    Repo.update!(
      Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - consumed_cents)
    )

    allocation =
      Repo.insert!(%Allocation{
        group_id: group_id,
        lot_id: lot.id,
        amount_cents: consumed_cents
      })

    consume_lots(
      rest,
      group_id,
      amount_cents - consumed_cents,
      [
        %{
          lot_id: lot.id,
          credit_allocation_id: allocation.id,
          amount_cents: consumed_cents
        }
        | consumed
      ]
    )
  end

  defp remove_group_allocation(nil, _amount), do: :ok

  defp remove_group_allocation(allocation_id, amount) do
    allocation = Repo.get!(Allocation, allocation_id)

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
      )
    end
  end
end
