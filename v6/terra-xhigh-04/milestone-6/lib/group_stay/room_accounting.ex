defmodule GroupStay.RoomAccounting do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.{
    CashPaymentTransferParticipation,
    CashRoomAllocation,
    FundingAllocationOrder,
    Group,
    HotelCreditApplication,
    Room
  }

  alias GroupStay.Repo

  @active "active"
  @held "held"

  def allocate_cash!(%Group{} = group, payment_operation_id, amount_cents)
      when is_binary(payment_operation_id) and is_integer(amount_cents) and amount_cents > 0 do
    allocate_to_rooms!(group, amount_cents, fn room, amount ->
      insert_cash_allocation!(%{
        group_id: group.id,
        group_room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: amount,
        disposition: @held
      })

      increment_room!(room.id, :cash_paid_cents, amount)
    end)
  end

  def held_funding_cents(%Group{} = group) do
    held_cash_for_group(group.id) + held_credit_for_group(group.id)
  end

  def transfer_held_funding!(%Group{} = source, %Group{} = destination, amount_cents)
      when is_integer(amount_cents) and amount_cents > 0 do
    {drawn_units, remaining} = take_funding_units(held_funding_units(source.id), amount_cents)

    if remaining != 0 do
      Repo.rollback(:held_funding_changed)
    end

    {assignments, unassigned_units} = destination_assignments(destination.id, drawn_units)

    if unassigned_units != [] or
         Enum.sum(Enum.map(assignments, & &1.amount_cents)) != amount_cents do
      Repo.rollback(:room_capacity_changed)
    end

    cash_cents =
      drawn_units
      |> Enum.filter(&(&1.kind == :cash))
      |> Enum.sum_by(& &1.amount_cents)

    Enum.each(drawn_units, &remove_transferred_unit!/1)
    Enum.each(assignments, &allocate_transferred_unit!/1)

    {:ok, cash_cents}
  end

  def allocate_hotel_credit_application!(attrs) when is_map(attrs) do
    insert_credit_application!(attrs)
  end

  def held_cash_for_payment(payment_operation_id) when is_binary(payment_operation_id) do
    Repo.one(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: allocation.group_room_id == room.id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == ^@held and room.status == ^@active,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  def held_cash_by_property do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: allocation.group_room_id == room.id,
        join: group in Group,
        on: allocation.group_id == group.id,
        where: allocation.disposition == ^@held and room.status == ^@active,
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
      )
    )
  end

  def reduce_payment!(payment_operation_id, amount_cents)
      when is_binary(payment_operation_id) and is_integer(amount_cents) and amount_cents > 0 do
    take_held_cash!(payment_operation_id, amount_cents, "reduced")
  end

  def charge_back_payment!(payment_operation_id) when is_binary(payment_operation_id) do
    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition not in ["reduced", "charged_back"],
          order_by: [desc: allocation.allocation_order]
        )
      )

    {charged_back_cents, affected_group_ids, group_amounts, disposition_amounts} =
      Enum.reduce(allocations, {0, MapSet.new(), %{}, %{}}, fn allocation,
                                                               {total, group_ids, group_amounts,
                                                                disposition_amounts} ->
        group_ids =
          if allocation.disposition == @held and allocation.group_room_id do
            increment_room!(allocation.group_room_id, :cash_paid_cents, -allocation.amount_cents)
            MapSet.put(group_ids, allocation.group_id)
          else
            group_ids
          end

        allocation
        |> Ecto.Changeset.change(disposition: "charged_back")
        |> Repo.update!()

        {total + allocation.amount_cents, group_ids,
         Map.update(
           group_amounts,
           allocation.group_id,
           allocation.amount_cents,
           &(&1 + allocation.amount_cents)
         ),
         Map.update(
           disposition_amounts,
           {allocation.group_id, allocation.disposition},
           allocation.amount_cents,
           &(&1 + allocation.amount_cents)
         )}
      end)

    {charged_back_cents, MapSet.to_list(affected_group_ids), group_amounts, disposition_amounts}
  end

  def settle_rooms_cash!(rooms, disposition, credit_lot_id \\ nil)
      when disposition in ["refunded", "retained", "converted"] do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: allocation.group_room_id == room.id,
          where: allocation.group_room_id in ^room_ids and allocation.disposition == ^@held,
          order_by: [asc: room.position, asc: allocation.id]
        )
      )

    Enum.each(allocations, fn allocation ->
      allocation
      |> Ecto.Changeset.change(%{disposition: disposition, credit_lot_id: credit_lot_id})
      |> Repo.update!()

      increment_room!(allocation.group_room_id, :cash_paid_cents, -allocation.amount_cents)
    end)

    {Enum.sum(Enum.map(allocations, & &1.amount_cents)), allocations}
  end

  def held_cash_for_rooms(rooms) when is_list(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.one(
      from(allocation in CashRoomAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.disposition == ^@held,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    dispositions =
      Repo.all(
        from(allocation in CashRoomAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id,
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    statement = %{
      held_cents: Map.get(dispositions, @held, 0),
      refunded_cents: Map.get(dispositions, "refunded", 0),
      retained_cents: Map.get(dispositions, "retained", 0),
      converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      reduced_cents: Map.get(dispositions, "reduced", 0),
      charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }

    if payment_participated_in_transfer?(payment_operation_id) do
      Map.put(statement, :held_by_group, held_cash_by_group(payment_operation_id))
    else
      statement
    end
  end

  def ledger_totals do
    dispositions =
      Repo.all(
        from(allocation in CashRoomAllocation,
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    %{
      cash_held_cents: Map.get(dispositions, @held, 0),
      cash_refunded_cents: Map.get(dispositions, "refunded", 0),
      cash_retained_cents: Map.get(dispositions, "retained", 0),
      cash_converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      cash_reduced_cents: Map.get(dispositions, "reduced", 0),
      cash_charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }
  end

  defp take_held_cash!(payment_operation_id, amount_cents, disposition) do
    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: allocation.group_room_id == room.id,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition == ^@held and room.status == ^@active,
          order_by: [desc: allocation.allocation_order],
          preload: [group_room: room]
        )
      )

    {remaining, removed, affected_group_ids, group_amounts} =
      Enum.reduce(allocations, {amount_cents, 0, MapSet.new(), %{}}, fn allocation,
                                                                        {remaining, removed,
                                                                         group_ids, group_amounts} ->
        to_remove = min(remaining, allocation.amount_cents)

        if to_remove == 0 do
          {remaining, removed, group_ids, group_amounts}
        else
          if to_remove == allocation.amount_cents do
            allocation
            |> Ecto.Changeset.change(disposition: disposition)
            |> Repo.update!()
          else
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - to_remove)
            |> Repo.update!()

            %CashRoomAllocation{}
            |> Ecto.Changeset.change(%{
              group_id: allocation.group_id,
              group_room_id: allocation.group_room_id,
              payment_operation_id: allocation.payment_operation_id,
              credit_lot_id: allocation.credit_lot_id,
              amount_cents: to_remove,
              disposition: disposition,
              allocation_order: next_allocation_order!()
            })
            |> Repo.insert!()
          end

          increment_room!(allocation.group_room_id, :cash_paid_cents, -to_remove)

          {remaining - to_remove, removed + to_remove, MapSet.put(group_ids, allocation.group_id),
           Map.update(group_amounts, allocation.group_id, to_remove, &(&1 + to_remove))}
        end
      end)

    if remaining == 0,
      do: {removed, MapSet.to_list(affected_group_ids), group_amounts},
      else: Repo.rollback(:held_cash_changed)
  end

  defp held_cash_for_group(group_id) do
    Repo.one(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: allocation.group_room_id == room.id,
        where:
          allocation.group_id == ^group_id and allocation.disposition == ^@held and
            room.status == ^@active,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  defp held_credit_for_group(group_id) do
    Repo.one(
      from(application in HotelCreditApplication,
        join: room in Room,
        on: application.group_room_id == room.id,
        where: application.group_id == ^group_id and room.status == ^@active,
        select: coalesce(sum(application.amount_cents), 0)
      )
    )
  end

  defp held_funding_units(group_id) do
    cash_units =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: allocation.group_room_id == room.id,
          where:
            allocation.group_id == ^group_id and allocation.disposition == ^@held and
              room.status == ^@active,
          select: allocation
        )
      )
      |> Enum.map(&%{kind: :cash, allocation: &1, amount_cents: &1.amount_cents})

    credit_units =
      Repo.all(
        from(application in HotelCreditApplication,
          join: room in Room,
          on: application.group_room_id == room.id,
          where: application.group_id == ^group_id and room.status == ^@active,
          select: application
        )
      )
      |> Enum.map(&%{kind: :credit, allocation: &1, amount_cents: &1.amount_cents})

    Enum.sort_by(
      cash_units ++ credit_units,
      fn unit ->
        allocation = unit.allocation
        {allocation.allocation_order, allocation.inserted_at, allocation.id}
      end,
      :desc
    )
  end

  defp take_funding_units(units, amount_cents) do
    {drawn_units, remaining} =
      Enum.reduce_while(units, {[], amount_cents}, fn unit, {drawn, remaining} ->
        if remaining == 0 do
          {:halt, {drawn, remaining}}
        else
          amount = min(unit.amount_cents, remaining)
          {:cont, {drawn ++ [%{unit | amount_cents: amount}], remaining - amount}}
        end
      end)

    {drawn_units, remaining}
  end

  defp destination_assignments(destination_group_id, drawn_units) do
    destination_group_id
    |> active_rooms()
    |> Enum.reduce({[], drawn_units}, fn room, {assignments, units} ->
      capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
      {room_assignments, remaining_units} = draw_units_for_room(units, room, capacity)
      {assignments ++ room_assignments, remaining_units}
    end)
  end

  defp draw_units_for_room(units, _room, 0), do: {[], units}
  defp draw_units_for_room([], _room, _capacity), do: {[], []}

  defp draw_units_for_room([unit | remaining_units], room, capacity) do
    amount = min(unit.amount_cents, capacity)
    assignment = %{unit: unit, room: room, amount_cents: amount}

    next_units =
      if amount == unit.amount_cents,
        do: remaining_units,
        else: [%{unit | amount_cents: unit.amount_cents - amount} | remaining_units]

    {following_assignments, next_units} =
      draw_units_for_room(next_units, room, capacity - amount)

    {[assignment | following_assignments], next_units}
  end

  defp remove_transferred_unit!(%{
         kind: :cash,
         allocation: allocation,
         amount_cents: amount_cents
       }) do
    mark_payment_transferred!(allocation.payment_operation_id)
    remove_or_shrink_allocation!(allocation, amount_cents)
    increment_room!(allocation.group_room_id, :cash_paid_cents, -amount_cents)
  end

  defp remove_transferred_unit!(%{
         kind: :credit,
         allocation: allocation,
         amount_cents: amount_cents
       }) do
    remove_or_shrink_allocation!(allocation, amount_cents)
    increment_room!(allocation.group_room_id, :credit_paid_cents, -amount_cents)
  end

  defp allocate_transferred_unit!(%{
         unit: %{kind: :cash, allocation: allocation},
         room: room,
         amount_cents: amount_cents
       }) do
    insert_cash_allocation!(%{
      group_id: room.group_id,
      group_room_id: room.id,
      payment_operation_id: allocation.payment_operation_id,
      credit_lot_id: allocation.credit_lot_id,
      amount_cents: amount_cents,
      disposition: @held
    })

    increment_room!(room.id, :cash_paid_cents, amount_cents)
  end

  defp allocate_transferred_unit!(%{
         unit: %{kind: :credit, allocation: allocation},
         room: room,
         amount_cents: amount_cents
       }) do
    insert_credit_application!(%{
      group_id: room.group_id,
      group_room_id: room.id,
      hotel_credit_lot_id: allocation.hotel_credit_lot_id,
      amount_cents: amount_cents
    })

    increment_room!(room.id, :credit_paid_cents, amount_cents)
  end

  defp remove_or_shrink_allocation!(allocation, amount_cents) do
    if amount_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount_cents)
      |> Repo.update!()
    end
  end

  defp insert_cash_allocation!(attrs) do
    %CashRoomAllocation{}
    |> Ecto.Changeset.change(Map.put(attrs, :allocation_order, next_allocation_order!()))
    |> Repo.insert!()
  end

  defp insert_credit_application!(attrs) do
    %HotelCreditApplication{}
    |> Ecto.Changeset.change(Map.put(attrs, :allocation_order, next_allocation_order!()))
    |> Repo.insert!()
  end

  defp next_allocation_order! do
    %FundingAllocationOrder{}
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp mark_payment_transferred!(payment_operation_id) when is_binary(payment_operation_id) do
    %CashPaymentTransferParticipation{}
    |> Ecto.Changeset.change(payment_operation_id: payment_operation_id)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :payment_operation_id)
  end

  defp mark_payment_transferred!(_payment_operation_id), do: :ok

  defp payment_participated_in_transfer?(payment_operation_id) do
    Repo.exists?(
      from(participation in CashPaymentTransferParticipation,
        where: participation.payment_operation_id == ^payment_operation_id
      )
    )
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: group in Group,
        on: allocation.group_id == group.id,
        join: room in Room,
        on: allocation.group_room_id == room.id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == ^@held and room.status == ^@active,
        group_by: group.group_id,
        order_by: [asc: group.group_id],
        select: %{group_id: group.group_id, amount_cents: sum(allocation.amount_cents)}
      )
    )
  end

  defp allocate_to_rooms!(group, amount_cents, allocate) do
    rooms = active_rooms(group.id)

    {remaining, _} =
      Enum.reduce(rooms, {amount_cents, 0}, fn room, {remaining, allocated} ->
        room_outstanding = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(max(room_outstanding, 0), remaining)

        if amount > 0, do: allocate.(room, amount)
        {remaining - amount, allocated + amount}
      end)

    if remaining == 0, do: :ok, else: Repo.rollback(:room_capacity_changed)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from(room in Room,
        where: room.group_id == ^group_id and room.status == ^@active,
        order_by: [asc: room.position]
      )
    )
  end

  defp increment_room!(room_id, field, amount_cents) do
    Repo.update_all(from(room in Room, where: room.id == ^room_id), inc: [{field, amount_cents}])
  end
end
