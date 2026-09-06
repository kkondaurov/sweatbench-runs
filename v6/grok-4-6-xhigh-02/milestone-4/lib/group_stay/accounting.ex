defmodule GroupStay.Accounting do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups
  alias GroupStay.Groups.CashPayment
  alias GroupStay.Groups.CreditEntitlement
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Groups.RoomAllocation
  alias GroupStay.Money
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  def fund_cash!(%Group{} = group, amount_cents, source_operation_id)
      when is_integer(amount_cents) and amount_cents > 0 do
    group = allocate!(group, amount_cents, "cash", source_operation_id, nil)

    %CashPayment{}
    |> CashPayment.changeset(%{
      operation_id: source_operation_id,
      group_id: group.group_id,
      recorded_cents: amount_cents,
      held_cents: amount_cents
    })
    |> Repo.insert!()

    sync_group_from_rooms!(group)
  end

  def fund_credit!(%Group{} = group, amount_cents, source_operation_id, %Date{} = occurred_on) do
    case Credit.take_from_lots(group.guest_id, amount_cents, occurred_on) do
      {:error, :insufficient_credit} ->
        {:error, :insufficient_credit}

      {:ok, takes} ->
        group = distribute_credit!(group, takes, source_operation_id)
        {:ok, sync_group_from_rooms!(group)}
    end
  end

  def settle_rooms!(%Group{} = group, rooms, occurred_on, refund_method, operation_id) do
    rooms = Enum.sort_by(rooms, & &1.position)
    cash = Enum.reduce(rooms, 0, fn room, acc -> acc + (room.cash_paid_cents || 0) end)
    refundable? = Groups.refundable?(group, occurred_on)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      if refundable? do
        restore_rooms_credit!(rooms, occurred_on)

        case refund_method do
          "hotel_credit" ->
            sources = cash_sources_in_funding_order(rooms)
            issued = Credit.issue_lot(group.guest_id, operation_id, cash, occurred_on)
            record_entitlements!(operation_id, sources, issued)
            move_held_cash!(rooms, :converted)
            {0, 0, cash, issued}

          "cash" ->
            move_held_cash!(rooms, :refunded)
            {cash, 0, 0, 0}
        end
      else
        consume_rooms_credit!(rooms)
        move_held_cash!(rooms, :retained)
        {0, cash, 0, 0}
      end

    Enum.each(rooms, fn room ->
      delete_allocations(room)

      room
      |> Room.changeset(%{
        status: "cancelled",
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
      |> Repo.update!()
    end)

    group = sync_group_from_rooms!(group)

    group =
      persist_group!(group, %{
        refunded_cents: (group.refunded_cents || 0) + refunded_cents,
        retained_cents: (group.retained_cents || 0) + retained_cents,
        cash_converted_to_credit_cents:
          (group.cash_converted_to_credit_cents || 0) + converted_cents
      })

    {group, refunded_cents, retained_cents, converted_cents, credit_issued_cents}
  end

  def reduce_held_cash!(%Group{} = group, %CashPayment{} = payment, amount_cents) do
    allocs =
      payment.operation_id
      |> allocations_for_payment()
      |> Enum.sort_by(& &1.fill_seq, :desc)

    peel_allocations!(allocs, amount_cents)

    payment =
      persist_payment!(payment, %{
        held_cents: payment.held_cents - amount_cents,
        reduced_cents: payment.reduced_cents + amount_cents
      })

    group =
      group
      |> reload_group()
      |> sync_group_from_rooms!()
      |> persist_group!(%{cash_reduced_cents: (group.cash_reduced_cents || 0) + amount_cents})

    {group, payment}
  end

  def charge_back!(%Group{} = group, %CashPayment{} = payment) do
    allocs = allocations_for_payment(payment.operation_id)
    held = payment.held_cents
    refunded = payment.refunded_cents
    retained = payment.retained_cents
    converted = payment.converted_to_credit_cents
    charged = held + refunded + retained + converted

    peel_allocations!(Enum.sort_by(allocs, & &1.fill_seq, :desc), held)

    Enum.each(entitlements_for_payment(payment.operation_id), fn entitlement ->
      lot = Repo.get!(GroupStay.Groups.CreditLot, entitlement.credit_lot_id)
      Credit.clawback_lot!(lot, entitlement.entitlement_cents)
    end)

    persist_payment!(payment, %{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: payment.charged_back_cents + charged
    })

    group =
      group
      |> reload_group()
      |> sync_group_from_rooms!()
      |> persist_group!(%{
        refunded_cents: max((group.refunded_cents || 0) - refunded, 0),
        retained_cents: max((group.retained_cents || 0) - retained, 0),
        cash_converted_to_credit_cents:
          max((group.cash_converted_to_credit_cents || 0) - converted, 0),
        cash_charged_back_cents: (group.cash_charged_back_cents || 0) + charged
      })

    {group, charged}
  end

  def get_cash_payment(operation_id) when is_binary(operation_id) do
    Repo.get_by(CashPayment, operation_id: operation_id)
  end

  def get_cash_payment(_), do: nil

  def payment_statement(%CashPayment{} = payment) do
    %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_to_credit_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }
  end

  def held_for_payment(%CashPayment{} = payment), do: payment.held_cents

  def chargeable_remainder(%CashPayment{} = payment) do
    payment.held_cents + payment.refunded_cents + payment.retained_cents +
      payment.converted_to_credit_cents
  end

  def applied_cash_payment?(%Operation{} = record) do
    record.type == "record_cash_payment" and applied?(record)
  end

  def applied?(%Operation{result: result}) when is_map(result) do
    result["status"] == "applied" or result[:status] == "applied"
  end

  def applied?(_), do: false

  def operation_group_id(%Operation{} = record) do
    from_result = result_value(record.result, "group_id")
    from_payload = result_value(record.payload, "group_id")
    from_result || from_payload
  end

  def sync_group_from_rooms!(%Group{} = group) do
    group = reload_group(group)
    rooms = ordered_rooms(group)
    active = Enum.reject(rooms, &(&1.status == "cancelled"))
    nights = Groups.nights(group.arrival_on, group.departure_on)
    cash = Enum.reduce(active, 0, fn room, acc -> acc + (room.cash_paid_cents || 0) end)
    credit = Enum.reduce(active, 0, fn room, acc -> acc + (room.credit_paid_cents || 0) end)

    {lodging, due} =
      if nights > 0 do
        {Groups.lodging_total_cents(active, nights),
         Groups.deposit_due_cents(active, nights, group.rate_plan)}
      else
        {0, 0}
      end

    status =
      if active == [] do
        "cancelled"
      else
        group.status
      end

    persist_group!(group, %{
      status: status,
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    })
  end

  def active_rooms(%Group{} = group) do
    group
    |> ordered_rooms()
    |> Enum.reject(&(&1.status == "cancelled"))
  end

  def telescoping_entitlements(sources) do
    {rows, _cash, _credit} =
      Enum.reduce(sources, {[], 0, 0}, fn {source_id, cash},
                                          {acc, running_cash, running_credit} ->
        running_cash = running_cash + cash
        new_credit = running_cash + Money.percent(running_cash, 10)
        entitlement = new_credit - running_credit
        {acc ++ [{source_id, cash, entitlement}], running_cash, new_credit}
      end)

    rows
  end

  def credit_shortfall_cents do
    lots =
      from(l in GroupStay.Groups.CreditLot, where: l.unrecovered_clawback_cents > 0)
      |> Repo.all()

    Enum.reduce(lots, 0, fn lot, acc ->
      applied = applied_credit_for_lot(lot.id)
      acc + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  def allocate_for_backfill!(group, amount, kind, source, lot_id) do
    allocate!(group, amount, kind, source, lot_id)
  end

  defp allocate!(%Group{} = group, amount_cents, kind, source_operation_id, credit_lot_id) do
    rooms = ordered_rooms(group)
    seq = next_fill_seq(group)

    {updated_by_id, _left, _seq} =
      Enum.reduce(rooms, {%{}, amount_cents, seq}, fn room, {map, left, seq} ->
        if room.status == "cancelled" or left == 0 do
          {Map.put(map, room.id, room), left, seq}
        else
          cap = remaining_capacity(room)
          take = min(cap, left)

          room =
            if take > 0 do
              insert_allocation!(room, kind, take, source_operation_id, credit_lot_id, seq)
              bump_room_paid!(room, kind, take)
            else
              room
            end

          seq = if take > 0, do: seq + 1, else: seq
          {Map.put(map, room.id, room), left - take, seq}
        end
      end)

    %{group | rooms: Enum.map(rooms, &Map.fetch!(updated_by_id, &1.id))}
  end

  defp distribute_credit!(group, takes, source_operation_id) do
    chunks =
      Enum.flat_map(takes, fn {lot, amount} ->
        [{lot, amount}]
      end)

    Enum.reduce(chunks, group, fn {lot, amount}, group ->
      allocate!(group, amount, "credit", source_operation_id, lot.id)
    end)
  end

  defp remaining_capacity(room) do
    due = room.deposit_due_cents || 0
    max(due - (room.cash_paid_cents || 0) - (room.credit_paid_cents || 0), 0)
  end

  defp bump_room_paid!(room, "cash", take) do
    persist_room!(room, %{cash_paid_cents: (room.cash_paid_cents || 0) + take})
  end

  defp bump_room_paid!(room, "credit", take) do
    persist_room!(room, %{credit_paid_cents: (room.credit_paid_cents || 0) + take})
  end

  defp insert_allocation!(room, kind, amount, source_operation_id, credit_lot_id, fill_seq) do
    %RoomAllocation{}
    |> RoomAllocation.changeset(%{
      room_id: room.id,
      kind: kind,
      amount_cents: amount,
      source_operation_id: source_operation_id,
      credit_lot_id: credit_lot_id,
      fill_seq: fill_seq
    })
    |> Repo.insert!()
  end

  defp next_fill_seq(group) do
    room_ids = Enum.map(ordered_rooms(group), & &1.id)

    case room_ids do
      [] ->
        1

      ids ->
        max_seq =
          from(a in RoomAllocation,
            where: a.room_id in ^ids,
            select: coalesce(max(a.fill_seq), 0)
          )
          |> Repo.one()

        max_seq + 1
    end
  end

  defp cash_sources_in_funding_order(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    allocs =
      from(a in RoomAllocation,
        where: a.room_id in ^room_ids and a.kind == "cash",
        order_by: [asc: a.fill_seq]
      )
      |> Repo.all()

    allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.map(fn {source, grouped} ->
      min_seq = grouped |> Enum.map(& &1.fill_seq) |> Enum.min()
      amount = Enum.reduce(grouped, 0, fn a, acc -> acc + a.amount_cents end)
      {source, amount, min_seq}
    end)
    |> Enum.sort_by(fn {source, _amount, min_seq} ->
      {if(is_nil(source), do: 0, else: 1), min_seq}
    end)
    |> Enum.map(fn {source, amount, _seq} -> {source, amount} end)
  end

  defp record_entitlements!(_operation_id, _sources, issued) when issued <= 0, do: :ok

  defp record_entitlements!(operation_id, sources, _issued) do
    lot = Repo.get_by!(GroupStay.Groups.CreditLot, source_operation_id: operation_id)

    sources
    |> telescoping_entitlements()
    |> Enum.with_index()
    |> Enum.each(fn {{source_id, cash, entitlement}, position} ->
      if cash > 0 do
        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: source_id,
          cash_cents: cash,
          entitlement_cents: entitlement,
          position: position
        })
        |> Repo.insert!()
      end
    end)
  end

  defp move_held_cash!(rooms, disposition) do
    room_ids = Enum.map(rooms, & &1.id)

    allocs =
      from(a in RoomAllocation,
        where: a.room_id in ^room_ids and a.kind == "cash"
      )
      |> Repo.all()

    allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.each(fn
      {nil, _allocs} ->
        :ok

      {operation_id, grouped} ->
        amount = Enum.reduce(grouped, 0, fn a, acc -> acc + a.amount_cents end)

        case get_cash_payment(operation_id) do
          nil ->
            :ok

          payment ->
            updates =
              case disposition do
                :refunded ->
                  %{
                    held_cents: payment.held_cents - amount,
                    refunded_cents: payment.refunded_cents + amount
                  }

                :retained ->
                  %{
                    held_cents: payment.held_cents - amount,
                    retained_cents: payment.retained_cents + amount
                  }

                :converted ->
                  %{
                    held_cents: payment.held_cents - amount,
                    converted_to_credit_cents: payment.converted_to_credit_cents + amount
                  }
              end

            persist_payment!(payment, updates)
        end
    end)
  end

  defp restore_rooms_credit!(rooms, occurred_on) do
    Enum.each(rooms, fn room ->
      room
      |> credit_allocations()
      |> Enum.each(fn alloc ->
        lot = Repo.get!(GroupStay.Groups.CreditLot, alloc.credit_lot_id)
        Credit.return_to_lot!(lot, alloc.amount_cents, occurred_on)
        Repo.delete!(alloc)
      end)
    end)
  end

  defp consume_rooms_credit!(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> credit_allocations()
      |> Enum.each(&Repo.delete!/1)
    end)
  end

  defp delete_allocations(room) do
    from(a in RoomAllocation, where: a.room_id == ^room.id)
    |> Repo.delete_all()
  end

  defp credit_allocations(room) do
    from(a in RoomAllocation, where: a.room_id == ^room.id and a.kind == "credit")
    |> Repo.all()
  end

  defp allocations_for_payment(operation_id) do
    from(a in RoomAllocation,
      where: a.source_operation_id == ^operation_id and a.kind == "cash"
    )
    |> Repo.all()
  end

  defp entitlements_for_payment(operation_id) do
    from(e in CreditEntitlement, where: e.payment_operation_id == ^operation_id)
    |> Repo.all()
  end

  defp peel_allocations!(_allocs, 0), do: :ok

  defp peel_allocations!(allocs, amount) do
    Enum.reduce_while(allocs, amount, fn alloc, left ->
      if left == 0 do
        {:halt, 0}
      else
        take = min(alloc.amount_cents, left)
        new_amount = alloc.amount_cents - take
        room = Repo.get!(Room, alloc.room_id)

        persist_room!(room, %{cash_paid_cents: max((room.cash_paid_cents || 0) - take, 0)})

        if new_amount == 0 do
          Repo.delete!(alloc)
        else
          alloc
          |> RoomAllocation.changeset(%{amount_cents: new_amount})
          |> Repo.update!()
        end

        {:cont, left - take}
      end
    end)
  end

  defp applied_credit_for_lot(lot_id) do
    from(a in RoomAllocation,
      join: r in Room,
      on: a.room_id == r.id,
      join: g in Group,
      on: r.group_id == g.id,
      where:
        a.credit_lot_id == ^lot_id and a.kind == "credit" and r.status == "active" and
          g.status == "active",
      select: coalesce(sum(a.amount_cents), 0)
    )
    |> Repo.one()
  end

  defp ordered_rooms(%Group{rooms: rooms}) when is_list(rooms) do
    Enum.sort_by(rooms, & &1.position)
  end

  defp reload_group(%Group{} = group) do
    Group
    |> Repo.get!(group.id)
    |> Repo.preload(:rooms, force: true)
  end

  defp persist_group!(group, changes) do
    group
    |> Group.changeset(changes)
    |> Repo.update!()
    |> Repo.preload(:rooms, force: true)
  end

  defp persist_room!(room, changes) do
    room
    |> Room.changeset(changes)
    |> Repo.update!()
  end

  defp persist_payment!(payment, changes) do
    payment
    |> CashPayment.changeset(changes)
    |> Repo.update!()
  end

  defp result_value(nil, _key), do: nil

  defp result_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, :group_id)
  end

  defp result_value(_, _), do: nil
end
