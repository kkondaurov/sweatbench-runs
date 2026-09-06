defmodule GroupStay.Accounting do
  import Ecto.Query

  alias GroupStay.{
    CashPayment,
    CreditApplication,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    Repo,
    Room,
    RoomFundingAllocation
  }

  @active "active"

  def ensure_all do
    Repo.all(from group in Group, where: group.accounting_initialized == false)
    |> Enum.each(&ensure_group/1)
  end

  def ensure_group(%Group{accounting_initialized: true} = group), do: group

  def ensure_group(group) do
    if Repo.in_transaction?() do
      initialize_group(group)
    else
      {:ok, initialized} = Repo.transaction(fn -> initialize_group(group) end, mode: :immediate)
      initialized
    end
  end

  defp initialize_group(group) do
    case Repo.get(Group, group.id) do
      %Group{accounting_initialized: true} = current ->
        current

      current ->
        backfill_group(current)

        Repo.update_all(
          from(item in Group,
            where: item.id == ^current.id and item.accounting_initialized == false
          ),
          set: [accounting_initialized: true]
        )

        Repo.get!(Group, current.id)
    end
  end

  def active_rooms(group) do
    Repo.all(
      from room in Room,
        where: room.group_record_id == ^group.id and room.status == @active,
        order_by: room.position
    )
  end

  def all_rooms(group) do
    Repo.all(
      from room in Room,
        where: room.group_record_id == ^group.id,
        order_by: room.position
    )
  end

  def room_totals(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    paid_by_room =
      if room_ids == [] do
        %{}
      else
        Repo.all(
          from allocation in RoomFundingAllocation,
            where: allocation.room_record_id in ^room_ids,
            group_by: [allocation.room_record_id, allocation.kind],
            select: {allocation.room_record_id, allocation.kind, sum(allocation.amount_cents)}
        )
        |> Enum.reduce(%{}, fn {room_id, kind, amount}, totals ->
          Map.update(totals, room_id, %{kind => amount}, &Map.put(&1, kind, amount))
        end)
      end

    Enum.map(rooms, fn room ->
      paid = Map.get(paid_by_room, room.id, %{})
      cash = Map.get(paid, "cash", 0)
      credit = Map.get(paid, "credit", 0)
      {room, cash, credit}
    end)
  end

  def group_totals(group) do
    rooms = active_rooms(group)
    detailed = room_totals(rooms)

    %{
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      cash_paid_cents: Enum.sum(Enum.map(detailed, fn {_room, cash, _credit} -> cash end)),
      credit_paid_cents: Enum.sum(Enum.map(detailed, fn {_room, _cash, credit} -> credit end))
    }
  end

  def fund_cash(group, source_operation_id, amount) do
    order = next_allocation_order(group)
    {_remaining, _order} = allocate_cash(group, source_operation_id, amount, order)
    :ok
  end

  def fund_credit(group, source_operation_id, lots, amount) do
    {segments, _remaining} =
      Enum.map_reduce(lots, amount, fn lot, needed ->
        used = min(lot.remaining_cents, needed)

        if used > 0 do
          Repo.update_all(
            from(item in CreditLot, where: item.id == ^lot.id),
            set: [remaining_cents: lot.remaining_cents - used]
          )
        end

        {{lot.id, used}, needed - used}
      end)

    segments = Enum.reject(segments, fn {_lot_id, used} -> used == 0 end)
    order = next_allocation_order(group)
    {_segments, _order} = allocate_credit(group, source_operation_id, segments, amount, order)
    :ok
  end

  def settle_rooms(group, rooms, operation_id, occurred_on, refund_method, refundable) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          where: allocation.room_record_id in ^room_ids,
          order_by: allocation.allocation_order
      )

    cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))
    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    credit = Enum.sum(Enum.map(credit_allocations, & &1.amount_cents))

    disposition =
      case {refundable, refund_method} do
        {true, "cash"} -> :refunded_cents
        {true, "hotel_credit"} -> :converted_to_credit_cents
        {false, "cash"} -> :retained_cents
      end

    cash_allocations
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.each(fn
      {nil, _items} -> :ok
      {source, items} -> settle_payment(source, items, disposition)
    end)

    issued =
      if refundable and refund_method == "hotel_credit" and cash > 0 do
        issue_credit(group, operation_id, occurred_on, cash_allocations)
      else
        0
      end

    Enum.each(credit_allocations, fn allocation ->
      if refundable, do: restore_credit(allocation, occurred_on)
    end)

    Repo.delete_all(
      from allocation in RoomFundingAllocation, where: allocation.room_record_id in ^room_ids
    )

    Repo.update_all(from(room in Room, where: room.id in ^room_ids), set: [status: "cancelled"])

    %{cash_cents: cash, credit_cents: credit, issued_cents: issued, disposition: disposition}
  end

  def remove_held_cash(group, payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in RoomFundingAllocation,
          join: room in Room,
          on: room.id == allocation.room_record_id,
          where:
            allocation.group_record_id == ^group.id and allocation.kind == "cash" and
              allocation.source_operation_id == ^payment_operation_id,
          order_by: [desc: room.position, desc: allocation.allocation_order]
      )

    Enum.reduce_while(allocations, amount, fn allocation, remaining ->
      removed = min(allocation.amount_cents, remaining)

      if removed == allocation.amount_cents do
        Repo.delete!(allocation)
      else
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed)
        |> Repo.update!()
      end

      if removed == remaining, do: {:halt, 0}, else: {:cont, remaining - removed}
    end)
  end

  def revoke_entitlements(payment_operation_id) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where:
          entitlement.payment_operation_id == ^payment_operation_id and
            entitlement.revoked == false
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - removed

      Repo.update_all(
        from(item in CreditLot, where: item.id == ^lot.id),
        set: [remaining_cents: lot.remaining_cents - removed],
        inc: [unrecovered_clawback_cents: unrecovered]
      )

      entitlement
      |> Ecto.Changeset.change(revoked: true)
      |> Repo.update!()
    end)
  end

  def credit_shortfall do
    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      applied =
        Repo.aggregate(
          from(allocation in RoomFundingAllocation,
            join: room in Room,
            on: room.id == allocation.room_record_id,
            where: allocation.credit_lot_id == ^lot.id and room.status == @active
          ),
          :sum,
          :amount_cents
        ) || 0

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp backfill_group(group) do
    records = funding_records(group.group_id)
    cash_records = Enum.filter(records, &(&1.operation_type == "record_cash_payment"))
    credit_records = Enum.filter(records, &(&1.operation_type == "apply_hotel_credit"))

    Enum.each(cash_records, &backfill_payment(group, &1))

    if group.status == @active do
      backfill_active_allocations(group, records, cash_records, credit_records)
    else
      backfill_settled_payments(group, cash_records)
      backfill_converted_entitlements(group, cash_records)
    end
  end

  defp funding_records(group_id) do
    Repo.all(
      from record in OperationRecord,
        where: record.operation_type in ["record_cash_payment", "apply_hotel_credit"],
        order_by: record.commit_order
    )
    |> Enum.filter(fn record ->
      result_value(record.result, "status") == "applied" and
        result_value(record.result, "group_id") == group_id
    end)
  end

  defp backfill_payment(group, record) do
    amount = result_value(record.result, "amount_cents")

    Repo.insert!(%CashPayment{
      payment_operation_id: record.operation_id,
      group_record_id: group.id,
      recorded_cents: amount,
      held_cents: if(group.status == @active, do: amount, else: 0)
    })
  end

  defp backfill_active_allocations(group, records, cash_records, credit_records) do
    durable_cash = Enum.sum(Enum.map(cash_records, &result_value(&1.result, "amount_cents")))
    durable_credit = Enum.sum(Enum.map(credit_records, &result_value(&1.result, "amount_cents")))
    legacy_cash = max(group.cash_paid_cents - durable_cash, 0)
    legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

    credit_segments =
      Repo.all(
        from application in CreditApplication,
          where: application.group_record_id == ^group.id,
          order_by: fragment("rowid"),
          select: {application.credit_lot_id, application.amount_cents}
      )

    order = 1
    {_remaining, order} = allocate_cash(group, nil, legacy_cash, order)

    {credit_segments, order} =
      allocate_credit(group, nil, credit_segments, legacy_credit, order)

    {_credit_segments, _order} =
      Enum.reduce(records, {credit_segments, order}, fn record, {segments, next_order} ->
        amount = result_value(record.result, "amount_cents")

        case record.operation_type do
          "record_cash_payment" ->
            {_remaining, following_order} =
              allocate_cash(group, record.operation_id, amount, next_order)

            {segments, following_order}

          "apply_hotel_credit" ->
            allocate_credit(group, record.operation_id, segments, amount, next_order)
        end
      end)

    Repo.delete_all(
      from application in CreditApplication, where: application.group_record_id == ^group.id
    )
  end

  defp backfill_settled_payments(group, cash_records) do
    field =
      cond do
        group.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        group.cash_refunded_cents > 0 -> :refunded_cents
        true -> :retained_cents
      end

    Enum.each(cash_records, fn record ->
      payment = Repo.get!(CashPayment, record.operation_id)
      amount = payment.recorded_cents

      payment
      |> Ecto.Changeset.change(%{field => amount})
      |> Repo.update!()
    end)
  end

  defp backfill_converted_entitlements(%Group{cash_converted_to_credit_cents: 0}, _records),
    do: :ok

  defp backfill_converted_entitlements(group, cash_records) do
    lot =
      Repo.all(CreditLot)
      |> Enum.find(fn lot ->
        case Repo.get_by(OperationRecord, operation_id: lot.source_operation_id) do
          nil -> false
          record -> result_value(record.result, "group_id") == group.group_id
        end
      end)

    if lot do
      durable = Enum.sum(Enum.map(cash_records, &result_value(&1.result, "amount_cents")))
      legacy = max(group.cash_converted_to_credit_cents - durable, 0)

      contributions =
        [{nil, legacy}] ++
          Enum.map(cash_records, fn record ->
            {record.operation_id, result_value(record.result, "amount_cents")}
          end)

      create_entitlements(lot, contributions)
    end
  end

  defp allocate_cash(_group, _source, 0, order), do: {0, order}

  defp allocate_cash(group, source, amount, order) do
    Enum.reduce_while(room_capacities(group), {amount, order}, fn {room, capacity},
                                                                  {remaining, next_order} ->
      used = min(capacity, remaining)

      if used > 0 do
        insert_allocation(group, room, "cash", source, nil, next_order, used)
      end

      if used == remaining do
        {:halt, {0, next_order + if(used > 0, do: 1, else: 0)}}
      else
        {:cont, {remaining - used, next_order + if(used > 0, do: 1, else: 0)}}
      end
    end)
  end

  defp allocate_credit(_group, _source, segments, 0, order), do: {segments, order}

  defp allocate_credit(group, source, segments, amount, order) do
    capacities = room_capacities(group)
    allocate_credit_parts(group, source, capacities, segments, amount, order)
  end

  defp allocate_credit_parts(_group, _source, _capacities, segments, 0, order),
    do: {segments, order}

  defp allocate_credit_parts(
         group,
         source,
         [{room, capacity} | rooms],
         [{lot_id, lot_amount} | lots],
         amount,
         order
       ) do
    used = min(min(capacity, lot_amount), amount)
    insert_allocation(group, room, "credit", source, lot_id, order, used)

    capacities = if used == capacity, do: rooms, else: [{room, capacity - used} | rooms]
    segments = if used == lot_amount, do: lots, else: [{lot_id, lot_amount - used} | lots]
    allocate_credit_parts(group, source, capacities, segments, amount - used, order + 1)
  end

  defp room_capacities(group) do
    group
    |> active_rooms()
    |> room_totals()
    |> Enum.map(fn {room, cash, credit} -> {room, room.deposit_due_cents - cash - credit} end)
    |> Enum.reject(fn {_room, capacity} -> capacity == 0 end)
  end

  defp insert_allocation(group, room, kind, source, lot_id, order, amount) do
    Repo.insert!(%RoomFundingAllocation{
      group_record_id: group.id,
      room_record_id: room.id,
      kind: kind,
      source_operation_id: source,
      credit_lot_id: lot_id,
      allocation_order: order,
      amount_cents: amount
    })
  end

  defp next_allocation_order(group) do
    (Repo.aggregate(
       from(allocation in RoomFundingAllocation,
         where: allocation.group_record_id == ^group.id
       ),
       :max,
       :allocation_order
     ) || 0) + 1
  end

  defp settle_payment(source, allocations, disposition) do
    amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))
    payment = Repo.get!(CashPayment, source)

    payment
    |> Ecto.Changeset.change(%{
      disposition => Map.fetch!(payment, disposition) + amount,
      :held_cents => payment.held_cents - amount
    })
    |> Repo.update!()
  end

  defp issue_credit(group, operation_id, occurred_on, cash_allocations) do
    contributions =
      cash_allocations
      |> Enum.group_by(& &1.source_operation_id)
      |> Enum.map(fn {source, items} ->
        {Enum.min_by(items, & &1.allocation_order).allocation_order, source,
         Enum.sum(Enum.map(items, & &1.amount_cents))}
      end)
      |> Enum.sort()
      |> Enum.map(fn {_order, source, amount} -> {source, amount} end)

    principal = Enum.sum(Enum.map(contributions, fn {_source, amount} -> amount end))
    issued = with_bonus(principal)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        issued_on_days: Date.to_gregorian_days(occurred_on),
        expires_on_days: occurred_on |> Date.add(365) |> Date.to_gregorian_days(),
        remaining_cents: issued
      })

    create_entitlements(lot, contributions)
    issued
  end

  defp create_entitlements(lot, contributions) do
    Enum.reduce(contributions, 0, fn {source, principal}, previous_principal ->
      running_principal = previous_principal + principal
      entitlement = with_bonus(running_principal) - with_bonus(previous_principal)

      if source && principal > 0 do
        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: source,
          principal_cents: principal,
          entitlement_cents: entitlement
        })
      end

      running_principal
    end)
  end

  defp restore_credit(allocation, occurred_on) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)
    excess = allocation.amount_cents - absorbed
    unexpired = Date.to_gregorian_days(occurred_on) <= lot.expires_on_days

    Repo.update_all(
      from(item in CreditLot, where: item.id == ^lot.id),
      set: [unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed],
      inc: [remaining_cents: if(unexpired, do: excess, else: 0)]
    )
  end

  defp with_bonus(principal), do: principal + div(principal * 10 + 50, 100)

  defp result_value(result, key), do: Map.get(result, key) || Map.get(result, String.to_atom(key))
end
