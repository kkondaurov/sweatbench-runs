defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Allocates deposit funding to rooms and maintains the active-room rollups.

  Funding fills rooms in their original order. A cross-kind allocation order
  records the exact sequence in which cash and credit reached rooms. Cash
  corrections walk the target payment's sequence backward across all groups.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditAllocation
  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Payments.{CashAllocation, CashPayment}
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @doc "The commit order the current durable operation will receive."
  def next_funding_order do
    (Repo.aggregate(OperationRecord, :max, :commit_order) || 0) + 1
  end

  @doc "The next order shared by cash and hotel-credit allocations."
  def next_allocation_order do
    cash_order = Repo.aggregate(CashAllocation, :max, :allocation_order) || 0
    credit_order = Repo.aggregate(CreditAllocation, :max, :allocation_order) || 0
    max(cash_order, credit_order) + 1
  end

  @doc "Allocates a newly recorded payment across active room requirements."
  def allocate_cash(%Group{} = group, %CashPayment{} = payment, amount_cents) do
    {amount_left, _next_order} =
      Enum.reduce(
        active_rooms(group),
        {amount_cents, next_allocation_order()},
        fn room, {amount_left, allocation_order} ->
          amount = min(room_capacity(room), amount_left)

          if amount > 0 do
            insert_cash_allocation!(
              group.id,
              room.id,
              payment.id,
              payment.funding_order,
              allocation_order,
              amount
            )

            update_room!(room, %{cash_paid_cents: room.cash_paid_cents + amount})
            {amount_left - amount, allocation_order + 1}
          else
            {amount_left, allocation_order}
          end
        end
      )

    if amount_left != 0, do: raise("validated cash did not fit active room deposits")

    refresh_group!(group)
  end

  @doc "Allocates credit lots across rooms while preserving both identities."
  def allocate_credit(%Group{} = group, lots, amount_cents, operation_id, funding_order) do
    {amount_left, _lots, _next_order} =
      Enum.reduce(
        active_rooms(group),
        {amount_cents, lots, next_allocation_order()},
        fn room, {amount_left, lots, allocation_order} ->
          room_capacity = room_capacity(room)
          room_amount = min(room_capacity, amount_left)
          {lots, pieces} = take_lot_pieces(lots, room_amount)

          allocation_order =
            Enum.reduce(pieces, allocation_order, fn {lot, amount}, allocation_order ->
              insert_credit_allocation!(
                group.id,
                room.id,
                lot.id,
                operation_id,
                funding_order,
                allocation_order,
                amount
              )

              allocation_order + 1
            end)

          if room_amount > 0 do
            update_room!(room, %{credit_paid_cents: room.credit_paid_cents + room_amount})
          end

          {amount_left - room_amount, lots, allocation_order}
        end
      )

    if amount_left != 0, do: raise("validated credit did not fit active room deposits")
    refresh_group!(group)
  end

  @doc "Returns selected active rooms in original order or `:invalid_rooms`."
  def select_active_rooms(%Group{} = group, room_ids) when is_list(room_ids) do
    valid_ids? =
      room_ids != [] and
        Enum.all?(room_ids, &(is_binary(&1) and String.trim(&1) != "")) and
        length(Enum.uniq(room_ids)) == length(room_ids)

    if valid_ids? do
      rooms =
        Room
        |> where([room], room.group_record_id == ^group.id)
        |> where([room], room.room_id in ^room_ids and room.status == "active")
        |> order_by([room], asc: room.position)
        |> Repo.all()

      if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  def select_active_rooms(%Group{}, _room_ids), do: {:error, :invalid_rooms}

  @doc "Returns every still-active room in original order."
  def active_rooms(%Group{} = group) do
    Room
    |> where([room], room.group_record_id == ^group.id and room.status == "active")
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  @doc "Clears held funding and marks the selected rooms cancelled."
  def mark_cancelled!(%Group{} = group, rooms) do
    Enum.each(rooms, fn room ->
      update_room!(room, %{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
    end)

    refresh_group!(group)
  end

  @doc "Removes held cash for one payment in reverse allocation order across groups."
  def reduce_cash!(%CashPayment{} = payment, amount_cents) do
    allocations =
      CashAllocation
      |> where([allocation], allocation.cash_payment_id == ^payment.id)
      |> order_by([allocation], desc: allocation.allocation_order)
      |> preload(:room)
      |> Repo.all()

    changed_group_ids = remove_from_cash_allocations(allocations, amount_cents, MapSet.new())

    changed_group_ids
    |> Enum.map(&Repo.get!(Group, &1))
    |> Enum.map(&refresh_group!/1)
  end

  @doc "Removes and returns all cash allocations on selected rooms."
  def take_room_cash_allocations(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      CashAllocation
      |> where([allocation], allocation.room_record_id in ^room_ids)
      |> order_by([allocation], asc: allocation.allocation_order)
      |> preload(:cash_payment)
      |> Repo.all()

    Repo.delete_all(
      from allocation in CashAllocation, where: allocation.room_record_id in ^room_ids
    )

    allocations
  end

  @doc "Recomputes every active-room aggregate and current group status."
  def refresh_group!(%Group{} = group) do
    rooms = active_rooms(group)

    totals =
      Enum.reduce(
        rooms,
        %{lodging: 0, due: 0, cash: 0, credit: 0},
        fn room, totals ->
          %{
            lodging: totals.lodging + room.lodging_total_cents,
            due: totals.due + room.deposit_due_cents,
            cash: totals.cash + room.cash_paid_cents,
            credit: totals.credit + room.credit_paid_cents
          }
        end
      )

    group
    |> Group.accounting_changeset(%{
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: totals.lodging,
      deposit_due_cents: totals.due,
      cash_paid_cents: totals.cash,
      credit_paid_cents: totals.credit,
      deposit_paid_cents: totals.cash + totals.credit
    })
    |> Repo.update!()
  end

  defp room_capacity(room) do
    max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
  end

  defp take_lot_pieces(lots, 0), do: {lots, []}

  defp take_lot_pieces([lot | lots], amount_left) do
    amount = min(lot.available_cents, amount_left)
    lot = %{lot | available_cents: lot.available_cents - amount}
    lots = if lot.available_cents == 0, do: lots, else: [lot | lots]
    {lots, pieces} = take_lot_pieces(lots, amount_left - amount)

    if amount == 0 do
      {lots, pieces}
    else
      {lots, [{lot.record, amount} | pieces]}
    end
  end

  defp take_lot_pieces([], amount_left) when amount_left > 0 do
    raise "validated available credit was exhausted during allocation"
  end

  defp insert_cash_allocation!(
         group_id,
         room_id,
         payment_id,
         funding_order,
         allocation_order,
         amount
       ) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      group_record_id: group_id,
      room_record_id: room_id,
      cash_payment_id: payment_id,
      funding_order: funding_order,
      allocation_order: allocation_order,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp insert_credit_allocation!(
         group_id,
         room_id,
         lot_id,
         operation_id,
         funding_order,
         allocation_order,
         amount
       ) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: lot_id,
      group_record_id: group_id,
      room_record_id: room_id,
      funding_operation_id: operation_id,
      funding_order: funding_order,
      allocation_order: allocation_order,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp shrink_or_delete_allocation!(allocation, removed) do
    remaining = allocation.amount_cents - removed

    if remaining == 0 do
      Repo.delete!(allocation)
    else
      allocation
      |> CashAllocation.changeset(%{amount_cents: remaining})
      |> Repo.update!()
    end
  end

  defp remove_from_cash_allocations(_allocations, 0, group_ids), do: group_ids

  defp remove_from_cash_allocations([allocation | rest], amount_left, group_ids) do
    removed = min(allocation.amount_cents, amount_left)
    shrink_or_delete_allocation!(allocation, removed)
    decrement_room_cash!(allocation.room_record_id, removed)

    remove_from_cash_allocations(
      rest,
      amount_left - removed,
      MapSet.put(group_ids, allocation.group_record_id)
    )
  end

  defp remove_from_cash_allocations([], amount_left, _group_ids) when amount_left > 0 do
    raise "payment held balance did not match its room allocations"
  end

  defp decrement_room_cash!(room_id, amount) do
    {1, _} =
      Room
      |> where([room], room.id == ^room_id)
      |> Repo.update_all(inc: [cash_paid_cents: -amount])
  end

  defp update_room!(room, attrs) do
    room |> Room.changeset(attrs) |> Repo.update!()
  end
end
