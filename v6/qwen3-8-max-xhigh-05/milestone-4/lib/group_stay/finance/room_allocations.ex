defmodule GroupStay.Finance.RoomAllocations do
  @moduledoc """
  Room-level funding allocations.

  Cash and credit fund active rooms in the rooms' original order, filling one
  room's deposit before moving to the next, and each funding operation
  appends its allocations in operation-processing order. Removals walk the
  held allocations of one payment in reverse fill order.
  """

  import Ecto.Query

  alias GroupStay.Finance.RoomAllocation
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

  Returns `{:ok, removed}` with one `{room_id, cents}` pair per removed
  portion, in removal order, or `{:error, :insufficient_held}` when the
  payment does not hold that much.
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

  # Removal

  defp do_remove(_rows, 0, _status, acc), do: {:ok, Enum.reverse(acc)}
  defp do_remove([], _remaining, _status, _acc), do: {:error, :insufficient_held}

  defp do_remove([row | rows], remaining, status, acc) do
    if row.amount_cents <= remaining do
      mark_row(row, status)

      do_remove(rows, remaining - row.amount_cents, status, [
        {row.room_id, row.amount_cents} | acc
      ])
    else
      split_row(row, row.amount_cents - remaining, status)
      do_remove(rows, 0, status, [{row.room_id, remaining} | acc])
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
