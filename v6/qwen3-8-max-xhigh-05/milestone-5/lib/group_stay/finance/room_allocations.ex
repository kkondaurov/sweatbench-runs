defmodule GroupStay.Finance.RoomAllocations do
  @moduledoc """
  Room-level funding allocations.

  Cash and credit fund active rooms in the rooms' original order, filling one
  room's deposit before moving to the next, and each funding operation
  appends its allocations in operation-processing order. Removals walk the
  held allocations of one payment in reverse fill order, wherever its
  allocations currently fund rooms. Deposit transfers take held funding in
  reverse fill order regardless of kind and place it into the destination's
  rooms in their original order, preserving the order in which portions were
  taken.
  """

  import Ecto.Query

  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @doc """
  Builds the cash allocation rows filling the given rooms (in order) with the
  given amount.
  """
  def fill_cash_rows(rooms, amount_cents, funding_operation_id) do
    timestamp = now()
    do_fill_cash(with_capacity(rooms), amount_cents, funding_operation_id, timestamp, [])
  end

  @doc """
  Builds the credit allocation rows filling the given rooms (in order) with
  the consumed lot segments, in segment order.
  """
  def fill_credit_rows(rooms, segments, funding_operation_id) do
    timestamp = now()
    do_fill_credit(with_capacity(rooms), segments, funding_operation_id, timestamp, [])
  end

  @doc """
  Inserts the allocation rows and adds their amounts to the rooms' paid
  totals for the given kind.
  """
  def insert_fill([], _kind), do: :ok

  def insert_fill(rows, kind) do
    Repo.insert_all(RoomAllocation, rows)

    rows
    |> Enum.group_by(& &1.room_id, & &1.amount_cents)
    |> Enum.each(fn {room_id, amounts} ->
      inc_room_paid(room_id, kind, Enum.sum(amounts))
    end)

    :ok
  end

  @doc """
  Returns the total held amount of the given kind across the rooms.
  """
  def held_sum(room_ids, kind) do
    Repo.one(
      from a in RoomAllocation,
        where: a.room_id in ^room_ids and a.kind == ^kind and a.status == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  @doc """
  Returns the held allocations for the rooms in fill order.
  """
  def held(room_ids) do
    Repo.all(
      from a in RoomAllocation,
        where: a.room_id in ^room_ids and a.status == "held",
        order_by: [asc: a.id]
    )
  end

  @doc """
  Moves the rooms' held allocations of the given kind to the new status,
  linking them to the given lot when provided.
  """
  def mark_held(room_ids, kind, new_status, lot_id \\ nil) do
    sets = [status: new_status, updated_at: now()]
    sets = if lot_id, do: Keyword.put(sets, :lot_id, lot_id), else: sets

    Repo.update_all(
      from(a in RoomAllocation,
        where: a.room_id in ^room_ids and a.kind == ^kind and a.status == "held"
      ),
      set: sets
    )

    :ok
  end

  @doc """
  Moves the payment's cash allocations in the given statuses to the new
  status.
  """
  def mark_payment(payment_operation_id, from_statuses, new_status) do
    Repo.update_all(
      from(a in RoomAllocation,
        where:
          a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.status in ^from_statuses
      ),
      set: [status: new_status, updated_at: now()]
    )

    :ok
  end

  @doc """
  Returns the payment's cash disposition totals keyed by status.
  """
  def disposition_sums(payment_operation_id) do
    RoomAllocation
    |> where([a], a.funding_operation_id == ^payment_operation_id and a.kind == "cash")
    |> group_by([a], a.status)
    |> select([a], {a.status, sum(a.amount_cents)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Removes held cash belonging to the payment in reverse fill order until the
  amount is reached, reclassifying the removed portions with the new status.

  Returns `{:ok, removed}` with one `{room_id, group_id, cents}` tuple per
  removed portion, in removal order, or `{:error, :insufficient_held}` when
  the payment does not hold that much.
  """
  def remove_held(payment_operation_id, amount_cents, new_status) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
              a.status == "held",
          order_by: [desc: a.id]
      )

    do_remove(rows, amount_cents, new_status, [])
  end

  @doc """
  Takes held allocations of any kind from the rooms in reverse fill order
  until the amount is reached.

  Fully taken allocations are left behind as `transferred` history; partially
  taken allocations keep their remaining amount. Returns `{:ok, portions}`
  with one portion map per taken slice, in the order taken, or
  `{:error, :insufficient_held}` when the rooms do not hold that much.
  """
  def take_held(rooms, amount_cents) do
    room_ids = Enum.map(rooms, & &1.id)

    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.room_id in ^room_ids and a.status == "held",
          order_by: [desc: a.id]
      )

    do_take(rows, amount_cents, [])
  end

  @doc """
  Builds the allocation rows placing the taken portions into the rooms (in
  order), preserving the order in which portions were taken. Each moved
  portion keeps its provenance and is marked as transferred.
  """
  def fill_transfer_rows(rooms, portions) do
    timestamp = now()

    segments =
      Enum.map(portions, &{&1.kind, &1.funding_operation_id, &1.lot_id, &1.amount_cents})

    do_fill_transfer(with_capacity(rooms), segments, timestamp, [])
  end

  @doc """
  Returns whether any of the payment's cash allocations have participated in
  a deposit transfer.
  """
  def cash_transferred?(payment_operation_id) do
    Repo.exists?(
      from a in RoomAllocation,
        where:
          a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.transferred == true
    )
  end

  @doc """
  Returns the payment's currently held cash by group, ordered by the partner
  group identifier, as `%{group_id: ..., amount_cents: ...}` maps.
  """
  def held_by_group(payment_operation_id) do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where:
          a.funding_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.status == "held",
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  @doc """
  Adjusts a room's paid total for the given kind by the (possibly negative)
  delta.
  """
  def inc_room_paid(room_id, "cash", delta) do
    Repo.update_all(from(r in Room, where: r.id == ^room_id), inc: [cash_paid_cents: delta])
    :ok
  end

  def inc_room_paid(room_id, "credit", delta) do
    Repo.update_all(from(r in Room, where: r.id == ^room_id), inc: [credit_paid_cents: delta])
    :ok
  end

  # Filling

  defp with_capacity(rooms) do
    Enum.map(rooms, fn room ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      {room, capacity}
    end)
  end

  defp do_fill_cash(_rooms, 0, _funding_operation_id, _timestamp, rows), do: Enum.reverse(rows)

  defp do_fill_cash([], _remaining, _funding_operation_id, _timestamp, rows),
    do: Enum.reverse(rows)

  defp do_fill_cash([{_room, 0} | rooms], remaining, funding_operation_id, timestamp, rows) do
    do_fill_cash(rooms, remaining, funding_operation_id, timestamp, rows)
  end

  defp do_fill_cash([{room, capacity} | rooms], remaining, funding_operation_id, timestamp, rows) do
    take = min(capacity, remaining)

    row =
      allocation_row(room, "cash", take, funding_operation_id, nil, "held", timestamp)

    rooms = if capacity - take > 0, do: [{room, capacity - take} | rooms], else: rooms
    do_fill_cash(rooms, remaining - take, funding_operation_id, timestamp, [row | rows])
  end

  defp do_fill_credit(_rooms, [], _funding_operation_id, _timestamp, rows),
    do: Enum.reverse(rows)

  defp do_fill_credit([], _segments, _funding_operation_id, _timestamp, rows),
    do: Enum.reverse(rows)

  defp do_fill_credit([{_room, 0} | rooms], segments, funding_operation_id, timestamp, rows) do
    do_fill_credit(rooms, segments, funding_operation_id, timestamp, rows)
  end

  defp do_fill_credit(
         [{room, capacity} | rooms],
         [{lot_id, amount} | segments],
         funding_operation_id,
         timestamp,
         rows
       ) do
    take = min(capacity, amount)

    row =
      allocation_row(room, "credit", take, funding_operation_id, lot_id, "held", timestamp)

    rooms = if capacity - take > 0, do: [{room, capacity - take} | rooms], else: rooms

    segments =
      if amount - take > 0, do: [{lot_id, amount - take} | segments], else: segments

    do_fill_credit(rooms, segments, funding_operation_id, timestamp, [row | rows])
  end

  defp allocation_row(room, kind, amount_cents, funding_operation_id, lot_id, status, timestamp) do
    %{
      group_id: room.group_id,
      room_id: room.id,
      kind: kind,
      funding_operation_id: funding_operation_id,
      lot_id: lot_id,
      amount_cents: amount_cents,
      status: status,
      inserted_at: timestamp,
      updated_at: timestamp
    }
  end

  # Transferring

  defp do_take(_rows, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp do_take([], _remaining, _acc), do: {:error, :insufficient_held}

  defp do_take([row | rows], remaining, acc) do
    if row.amount_cents <= remaining do
      mark_row(row, "transferred")

      do_take(rows, remaining - row.amount_cents, [
        taken_portion(row, row.amount_cents) | acc
      ])
    else
      shrink_row(row, row.amount_cents - remaining)
      do_take(rows, 0, [taken_portion(row, remaining) | acc])
    end
  end

  defp taken_portion(row, amount_cents) do
    %{
      room_id: row.room_id,
      kind: row.kind,
      funding_operation_id: row.funding_operation_id,
      lot_id: row.lot_id,
      amount_cents: amount_cents
    }
  end

  defp shrink_row(row, kept_amount) do
    Repo.update_all(
      from(a in RoomAllocation, where: a.id == ^row.id),
      set: [amount_cents: kept_amount, updated_at: now()]
    )

    :ok
  end

  defp do_fill_transfer(_rooms, [], _timestamp, rows), do: Enum.reverse(rows)
  defp do_fill_transfer([], _segments, _timestamp, rows), do: Enum.reverse(rows)

  defp do_fill_transfer([{_room, 0} | rooms], segments, timestamp, rows) do
    do_fill_transfer(rooms, segments, timestamp, rows)
  end

  defp do_fill_transfer(
         [{room, capacity} | rooms],
         [{kind, funding_operation_id, lot_id, amount} | segments],
         timestamp,
         rows
       ) do
    take = min(capacity, amount)

    row =
      room
      |> allocation_row(kind, take, funding_operation_id, lot_id, "held", timestamp)
      |> Map.put(:transferred, true)

    rooms = if capacity - take > 0, do: [{room, capacity - take} | rooms], else: rooms

    segments =
      if amount - take > 0,
        do: [{kind, funding_operation_id, lot_id, amount - take} | segments],
        else: segments

    do_fill_transfer(rooms, segments, timestamp, [row | rows])
  end

  # Removal

  defp do_remove(_rows, 0, _status, acc), do: {:ok, Enum.reverse(acc)}
  defp do_remove([], _remaining, _status, _acc), do: {:error, :insufficient_held}

  defp do_remove([row | rows], remaining, status, acc) do
    if row.amount_cents <= remaining do
      mark_row(row, status)

      do_remove(rows, remaining - row.amount_cents, status, [
        {row.room_id, row.group_id, row.amount_cents} | acc
      ])
    else
      split_row(row, row.amount_cents - remaining, status)
      do_remove(rows, 0, status, [{row.room_id, row.group_id, remaining} | acc])
    end
  end

  defp mark_row(row, status) do
    Repo.update_all(
      from(a in RoomAllocation, where: a.id == ^row.id),
      set: [status: status, updated_at: now()]
    )

    :ok
  end

  defp split_row(row, kept_amount, status) do
    removed_cents = row.amount_cents - kept_amount
    timestamp = now()

    Repo.update_all(
      from(a in RoomAllocation, where: a.id == ^row.id),
      set: [amount_cents: kept_amount, updated_at: timestamp]
    )

    Repo.insert_all(RoomAllocation, [
      %{
        group_id: row.group_id,
        room_id: row.room_id,
        kind: row.kind,
        funding_operation_id: row.funding_operation_id,
        lot_id: row.lot_id,
        amount_cents: removed_cents,
        status: status,
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
