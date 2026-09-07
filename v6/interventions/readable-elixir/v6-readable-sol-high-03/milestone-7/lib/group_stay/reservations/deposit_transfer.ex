defmodule GroupStay.Reservations.DepositTransfer do
  @moduledoc """
  Reassigns held cash and hotel credit between active groups.

  A transfer draws from the newest allocation first across both funding kinds,
  then fills destination rooms in partner order. Only allocation ownership
  changes: cash dispositions, credit balances, expiry, and ledger totals are
  deliberately untouched.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    AllocationOrder,
    CashAllocation,
    CashFunding,
    CreditAllocation,
    Group,
    Room,
    RoomAccounting
  }

  @type moved_unit ::
          {:cash, pos_integer(), pos_integer()}
          | {:credit, pos_integer(), String.t() | nil, pos_integer()}

  @doc "Moves an already-validated amount and preserves every funding source."
  def move(%Group{} = source, %Group{} = destination, amount_cents) do
    units = draw_units(source.group_id, amount_cents)
    mark_transferred_payments(units)
    allocate_units(RoomAccounting.active_rooms(destination.group_id), units, destination.group_id)
    :ok
  end

  defp draw_units(source_group_id, amount_cents) do
    allocations = source_allocations(source_group_id)
    {drawn, remaining_cents} = take_allocations(allocations, amount_cents, [])

    if remaining_cents > 0 do
      raise "transfer exceeds held funding by #{remaining_cents} cents"
    end

    update_source_rooms(drawn)
    Enum.map(drawn, &moved_unit/1)
  end

  defp source_allocations(group_id) do
    cash =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id and room.status == "active",
          select: {:cash, allocation}
      )

    credit =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.group_id == ^group_id and room.status == "active",
          select: {:credit, allocation}
      )

    Enum.sort_by(cash ++ credit, fn {_kind, allocation} -> allocation.allocation_order end, :desc)
  end

  defp take_allocations(_allocations, 0, drawn), do: {Enum.reverse(drawn), 0}
  defp take_allocations([], remaining_cents, drawn), do: {Enum.reverse(drawn), remaining_cents}

  defp take_allocations([{kind, allocation} | allocations], remaining_cents, drawn) do
    moved_cents = min(allocation.amount_cents, remaining_cents)

    if moved_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - moved_cents)
      |> Repo.update!()
    end

    take_allocations(
      allocations,
      remaining_cents - moved_cents,
      [{kind, allocation, moved_cents} | drawn]
    )
  end

  defp update_source_rooms(drawn) do
    drawn
    |> Enum.group_by(fn {_kind, allocation, _amount_cents} -> allocation.room_id end)
    |> Enum.each(fn {room_id, room_draws} ->
      room = Repo.get!(Room, room_id)

      cash_cents =
        room_draws
        |> Enum.filter(&(elem(&1, 0) == :cash))
        |> Enum.sum_by(&elem(&1, 2))

      credit_cents =
        room_draws
        |> Enum.filter(&(elem(&1, 0) == :credit))
        |> Enum.sum_by(&elem(&1, 2))

      room
      |> Room.accounting_changeset(%{
        cash_paid_cents: room.cash_paid_cents - cash_cents,
        credit_paid_cents: room.credit_paid_cents - credit_cents
      })
      |> Repo.update!()
    end)
  end

  defp moved_unit({:cash, allocation, amount_cents}),
    do: {:cash, allocation.cash_funding_id, amount_cents}

  defp moved_unit({:credit, allocation, amount_cents}),
    do: {:credit, allocation.credit_lot_id, allocation.funding_operation_id, amount_cents}

  defp mark_transferred_payments(units) do
    units
    |> Enum.flat_map(fn
      {:cash, funding_id, _amount_cents} -> [funding_id]
      {:credit, _lot_id, _operation_id, _amount_cents} -> []
    end)
    |> Enum.uniq()
    |> Enum.each(fn funding_id ->
      funding = Repo.get!(CashFunding, funding_id)

      unless funding.participated_in_transfer do
        funding
        |> CashFunding.disposition_changeset(%{participated_in_transfer: true})
        |> Repo.update!()
      end
    end)
  end

  defp allocate_units(_rooms, [], _group_id), do: :ok

  defp allocate_units([], [unit | _units], _group_id) do
    raise "transfer exceeds destination room capacity by #{unit_amount(unit)} cents"
  end

  defp allocate_units([room | rooms], [unit | units], group_id) do
    room_capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    allocated_cents = min(room_capacity, unit_amount(unit))

    if allocated_cents == 0 do
      allocate_units(rooms, [unit | units], group_id)
    else
      insert_destination_allocation(unit, room, group_id, allocated_cents)

      field = if elem(unit, 0) == :cash, do: :cash_paid_cents, else: :credit_paid_cents

      updated_room =
        room
        |> Room.accounting_changeset(%{field => Map.fetch!(room, field) + allocated_cents})
        |> Repo.update!()

      remaining_unit = put_unit_amount(unit, unit_amount(unit) - allocated_cents)

      if unit_amount(remaining_unit) == 0 do
        allocate_units([updated_room | rooms], units, group_id)
      else
        allocate_units(rooms, [remaining_unit | units], group_id)
      end
    end
  end

  defp insert_destination_allocation({:cash, funding_id, _amount}, room, _group_id, amount) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      cash_funding_id: funding_id,
      room_id: room.id,
      amount_cents: amount,
      allocation_order: AllocationOrder.next()
    })
    |> Repo.insert!()
  end

  defp insert_destination_allocation(
         {:credit, lot_id, operation_id, _amount},
         room,
         group_id,
         amount
       ) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: lot_id,
      group_id: group_id,
      room_id: room.id,
      funding_operation_id: operation_id,
      amount_cents: amount,
      allocation_order: AllocationOrder.next()
    })
    |> Repo.insert!()
  end

  defp unit_amount({:cash, _funding_id, amount_cents}), do: amount_cents
  defp unit_amount({:credit, _lot_id, _operation_id, amount_cents}), do: amount_cents

  defp put_unit_amount({:cash, funding_id, _amount_cents}, amount_cents),
    do: {:cash, funding_id, amount_cents}

  defp put_unit_amount({:credit, lot_id, operation_id, _amount_cents}, amount_cents),
    do: {:credit, lot_id, operation_id, amount_cents}
end
