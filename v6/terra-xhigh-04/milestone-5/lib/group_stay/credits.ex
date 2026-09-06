defmodule GroupStay.Credits do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.{
    Group,
    HotelCreditApplication,
    HotelCreditLot,
    HotelCreditLotEntitlement,
    Room
  }

  alias GroupStay.{Repo, RoomAccounting}

  @active "active"

  def guest_credit(guest_id, on) when is_binary(guest_id) and is_struct(on, Date) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
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

  def guest_credit(_guest_id, _on), do: %{guest_id: nil, available_cents: 0, lots: []}

  def consume!(%Group{} = group, amount_cents, on)
      when is_integer(amount_cents) and amount_cents > 0 and is_struct(on, Date) do
    lots = available_lots(group.guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, :insufficient_credit}
    else
      assignments = credit_assignments(group.id, lots, amount_cents)

      if Enum.sum(Enum.map(assignments, & &1.amount_cents)) != amount_cents do
        Repo.rollback(:room_capacity_changed)
      end

      assignments
      |> Enum.group_by(& &1.hotel_credit_lot_id)
      |> Enum.each(fn {lot_id, lot_assignments} ->
        amount_from_lot = Enum.sum(Enum.map(lot_assignments, & &1.amount_cents))

        case Repo.update_all(
               from(lot in HotelCreditLot,
                 where:
                   lot.id == ^lot_id and lot.remaining_cents >= ^amount_from_lot and
                     lot.expires_on > ^on
               ),
               inc: [remaining_cents: -amount_from_lot]
             ) do
          {1, _} -> :ok
          {0, _} -> Repo.rollback(:retry)
        end
      end)

      Enum.each(assignments, fn assignment ->
        RoomAccounting.allocate_hotel_credit_application!(%{
          group_id: group.id,
          group_room_id: assignment.group_room_id,
          hotel_credit_lot_id: assignment.hotel_credit_lot_id,
          amount_cents: assignment.amount_cents
        })

        increment_room!(assignment.group_room_id, :credit_paid_cents, assignment.amount_cents)
      end)

      :ok
    end
  end

  def issue!(guest_id, source_operation_id, cash_cents, cancelled_on)
      when is_binary(guest_id) and is_binary(source_operation_id) and is_integer(cash_cents) and
             cash_cents >= 0 and is_struct(cancelled_on, Date) do
    credit_cents = credit_value(cash_cents)

    lot =
      if credit_cents > 0 do
        %HotelCreditLot{}
        |> Ecto.Changeset.change(%{
          guest_id: guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: credit_cents,
          expires_on: Date.add(cancelled_on, 366)
        })
        |> Repo.insert!()
      end

    {credit_cents, lot}
  end

  def record_entitlements!(nil, _cash_allocations), do: :ok

  def record_entitlements!(%HotelCreditLot{} = lot, cash_allocations) do
    cash_allocations
    |> Enum.reduce({0, []}, fn allocation, {previous_cash, entitlements} ->
      current_cash = previous_cash + allocation.amount_cents
      entitlement_cents = credit_value(current_cash) - credit_value(previous_cash)

      case entitlements do
        [%{payment_operation_id: payment_operation_id} = last | rest]
        when payment_operation_id == allocation.payment_operation_id ->
          {current_cash, [%{last | amount_cents: last.amount_cents + entitlement_cents} | rest]}

        _ ->
          {current_cash,
           [
             %{
               payment_operation_id: allocation.payment_operation_id,
               amount_cents: entitlement_cents
             }
             | entitlements
           ]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.each(fn entitlement ->
      %HotelCreditLotEntitlement{}
      |> Ecto.Changeset.change(Map.put(entitlement, :hotel_credit_lot_id, lot.id))
      |> Repo.insert!()
    end)
  end

  def restore_rooms_credit!(rooms, cancelled_on)
      when is_list(rooms) and is_struct(cancelled_on, Date) do
    applications_for_rooms(rooms)
    |> Enum.each(fn application ->
      lot = Repo.get!(HotelCreditLot, application.hotel_credit_lot_id)
      absorbed = min(lot.unrecovered_clawback_cents, application.amount_cents)
      amount_to_restore = application.amount_cents - absorbed

      if absorbed > 0 do
        Repo.update_all(
          from(current_lot in HotelCreditLot, where: current_lot.id == ^lot.id),
          inc: [unrecovered_clawback_cents: -absorbed]
        )
      end

      if amount_to_restore > 0 and Date.compare(lot.expires_on, cancelled_on) == :gt do
        Repo.update_all(
          from(current_lot in HotelCreditLot, where: current_lot.id == ^lot.id),
          inc: [remaining_cents: amount_to_restore]
        )
      end

      increment_room!(application.group_room_id, :credit_paid_cents, -application.amount_cents)
      Repo.delete!(application)
    end)
  end

  def consume_rooms_credit!(rooms) when is_list(rooms) do
    applications_for_rooms(rooms)
    |> Enum.each(fn application ->
      increment_room!(application.group_room_id, :credit_paid_cents, -application.amount_cents)
      Repo.delete!(application)
    end)
  end

  def revoke_payment_entitlements!(payment_operation_id) when is_binary(payment_operation_id) do
    Repo.all(
      from(entitlement in HotelCreditLotEntitlement,
        join: lot in HotelCreditLot,
        on: entitlement.hotel_credit_lot_id == lot.id,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        preload: [hotel_credit_lot: lot]
      )
    )
    |> Enum.each(fn entitlement ->
      lot = entitlement.hotel_credit_lot
      revoked_from_remaining = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered = entitlement.amount_cents - revoked_from_remaining

      if revoked_from_remaining > 0 do
        Repo.update_all(
          from(current_lot in HotelCreditLot, where: current_lot.id == ^lot.id),
          inc: [remaining_cents: -revoked_from_remaining]
        )
      end

      if unrecovered > 0 do
        Repo.update_all(
          from(current_lot in HotelCreditLot, where: current_lot.id == ^lot.id),
          inc: [unrecovered_clawback_cents: unrecovered]
        )
      end
    end)
  end

  def liability_cents(on) when is_struct(on, Date) do
    available =
      Repo.one(
        from(lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
        )
      )

    applied =
      Repo.one(
        from(application in HotelCreditApplication,
          join: room in Room,
          on: application.group_room_id == room.id,
          where: room.status == ^@active,
          select: coalesce(sum(application.amount_cents), 0)
        )
      )

    available + applied
  end

  def shortfall_cents do
    Repo.all(
      from(lot in HotelCreditLot,
        left_join: application in HotelCreditApplication,
        on: application.hotel_credit_lot_id == lot.id,
        left_join: room in Room,
        on: application.group_room_id == room.id and room.status == ^@active,
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select:
          {lot.unrecovered_clawback_cents,
           coalesce(
             sum(
               fragment(
                 "CASE WHEN ? IS NULL THEN 0 ELSE ? END",
                 room.id,
                 application.amount_cents
               )
             ),
             0
           )}
      )
    )
    |> Enum.reduce(0, fn {unrecovered, applied}, total -> total + min(unrecovered, applied) end)
  end

  def credit_value(cash_cents), do: cash_cents + round_percentage(cash_cents, 10)

  defp credit_assignments(group_id, lots, amount_cents) do
    rooms =
      Repo.all(
        from(room in Room,
          where: room.group_id == ^group_id and room.status == ^@active,
          order_by: [asc: room.position]
        )
      )

    {assignments, _lots, _remaining} =
      Enum.reduce(rooms, {[], Enum.map(lots, &Map.from_struct/1), amount_cents}, fn room,
                                                                                    {assignments,
                                                                                     lots,
                                                                                     remaining} ->
        room_amount =
          min(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, remaining)

        room_amount = max(room_amount, 0)
        {room_assignments, lots} = take_from_lots(lots, room_amount)

        {assignments ++ Enum.map(room_assignments, &Map.put(&1, :group_room_id, room.id)), lots,
         remaining - room_amount}
      end)

    assignments
  end

  defp take_from_lots(lots, amount_cents) do
    {assignments, lots, _remaining} =
      Enum.reduce(lots, {[], [], amount_cents}, fn lot, {assignments, updated_lots, remaining} ->
        amount = min(lot.remaining_cents, remaining)
        updated_lot = %{lot | remaining_cents: lot.remaining_cents - amount}

        assignments =
          if amount > 0 do
            assignments ++ [%{hotel_credit_lot_id: lot.id, amount_cents: amount}]
          else
            assignments
          end

        {assignments, updated_lots ++ [updated_lot], remaining - amount}
      end)

    {assignments, lots}
  end

  defp applications_for_rooms([]), do: []

  defp applications_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from(application in HotelCreditApplication, where: application.group_room_id in ^room_ids)
    )
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
    )
  end

  defp increment_room!(room_id, field, amount_cents) do
    Repo.update_all(from(room in Room, where: room.id == ^room_id), inc: [{field, amount_cents}])
  end

  defp round_percentage(amount_cents, percentage),
    do: div(amount_cents * percentage + 50, 100)
end
