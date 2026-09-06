defmodule GroupStay.Finance.Allocations do
  @moduledoc """
  The room-level funding ledger.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Funding operations
  allocate in operation-processing order. Allocations exist only while funding
  is held; settlements, reductions, and chargebacks remove them.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Room
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Repo

  @typedoc "A unit of recorded funding awaiting allocation onto rooms."
  @type entry :: %{
          required(:funding_type) => String.t(),
          optional(:source_operation_id) => String.t() | nil,
          optional(:credit_lot_id) => Ecto.UUID.t() | nil,
          required(:amount_cents) => pos_integer()
        }

  @doc """
  Allocates the given funding entries onto the group's active rooms in
  original room order, filling one room before moving to the next.
  """
  @spec allocate(Ecto.UUID.t(), [entry()]) :: :ok
  def allocate(group_id, entries) do
    capacities = room_capacities(group_id)

    {rows, _} =
      Enum.flat_map_reduce(entries, {capacities, next_fill_order()}, fn entry,
                                                                        {remaining, fill_order} ->
        {slices, _left} = fill_rooms(remaining, entry.amount_cents, [])
        slices = Enum.reverse(slices)

        rows =
          Enum.with_index(slices, fn {room_id, amount}, index ->
            %RoomAllocation{
              group_id: group_id,
              room_id: room_id,
              funding_type: entry.funding_type,
              source_operation_id: Map.get(entry, :source_operation_id),
              credit_lot_id: Map.get(entry, :credit_lot_id),
              amount_cents: amount,
              fill_order: fill_order + index
            }
          end)

        taken =
          Enum.reduce(slices, %{}, fn {room_id, amount}, acc ->
            Map.update(acc, room_id, amount, &(&1 + amount))
          end)

        remaining =
          Enum.map(remaining, fn {room_id, capacity} ->
            {room_id, capacity - Map.get(taken, room_id, 0)}
          end)

        {rows, {remaining, fill_order + length(rows)}}
      end)

    Enum.each(rows, &Repo.insert!/1)

    :ok
  end

  defp fill_rooms([{room_id, capacity} | rest], left, acc) when left > 0 do
    take = min(max(capacity, 0), left)

    if take > 0 do
      fill_rooms(rest, left - take, [{room_id, take} | acc])
    else
      fill_rooms(rest, left, acc)
    end
  end

  defp fill_rooms([], left, _acc) when left > 0 do
    raise("funding exceeds active room deposit capacity")
  end

  defp fill_rooms(_rest, 0, acc), do: {acc, 0}

  @doc """
  The cash and credit currently held on each of the group's rooms, keyed by
  room primary key.
  """
  @spec paid_by_room(Ecto.UUID.t()) :: %{Ecto.UUID.t() => %{cash: integer(), credit: integer()}}
  def paid_by_room(group_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_id,
        group_by: [a.room_id, a.funding_type],
        select: {a.room_id, a.funding_type, coalesce(sum(a.amount_cents), 0)}
    )
    |> Enum.reduce(%{}, fn {room_id, funding_type, amount}, acc ->
      key = if funding_type == "cash", do: :cash, else: :credit

      entry =
        acc
        |> Map.get(room_id, %{cash: 0, credit: 0})
        |> Map.update!(key, &(&1 + amount))

      Map.put(acc, room_id, entry)
    end)
  end

  @doc """
  The total cash from one payment still held on active rooms.
  """
  @spec held_cash_for_source(String.t()) :: integer()
  def held_cash_for_source(source_operation_id) do
    from(a in RoomAllocation,
      where: a.funding_type == "cash" and a.source_operation_id == ^source_operation_id
    )
    |> Repo.aggregate(:sum, :amount_cents) || 0
  end

  @doc """
  The total cash and credit currently held on the group's active rooms.
  """
  @spec held_funding(Ecto.UUID.t()) :: integer()
  def held_funding(group_id) do
    held_by_room(group_id) |> Map.values() |> Enum.sum()
  end

  @doc """
  Draws exactly `amount` cents of the group's held funding (cash and credit
  alike) from its active rooms in reverse allocation order, most recently
  created allocation first. Removes or trims the allocation rows and returns
  the drawn units in the order they were drawn, each keeping its provenance.

  Raises when the group holds less than `amount`.
  """
  @spec take_funding_reverse(Ecto.UUID.t(), pos_integer()) :: [entry()]
  def take_funding_reverse(group_id, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          join: r in Room,
          on: r.id == a.room_id,
          where: a.group_id == ^group_id and r.status == "active",
          order_by: [desc: a.fill_order]
      )

    {units, left} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {units, left} ->
        take = min(allocation.amount_cents, left)

        if take == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - take)
          |> Repo.update!()
        end

        unit = %{
          funding_type: allocation.funding_type,
          source_operation_id: allocation.source_operation_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: take
        }

        case left - take do
          0 -> {:halt, {[unit | units], 0}}
          rest -> {:cont, {[unit | units], rest}}
        end
      end)

    if left > 0 do
      raise("transfer exceeds the source group's held funding")
    end

    Enum.reverse(units)
  end

  @doc """
  Removes exactly `amount` cents of one payment's held allocations in reverse
  fill order, across every group they currently fund. Raises when the payment
  holds less than `amount`. Returns the primary keys of the groups whose
  allocations were removed or trimmed.
  """
  @spec release_held_cash(String.t(), pos_integer()) :: {:ok, [Ecto.UUID.t()]}
  def release_held_cash(source_operation_id, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          where: a.funding_type == "cash" and a.source_operation_id == ^source_operation_id,
          order_by: [desc: a.fill_order]
      )

    case remove_amounts(allocations, amount) do
      {:ok, removed} -> {:ok, removed |> Enum.map(& &1.group_id) |> Enum.uniq()}
      :insufficient -> raise("reduction exceeds the payment's held allocations")
    end
  end

  @doc """
  Removes exactly `amount` cents across the given allocation rows, consuming
  whole rows where possible and trimming the final one. Returns the rows that
  were removed or trimmed.
  """
  @spec remove_amounts([RoomAllocation.t()], non_neg_integer()) ::
          {:ok, [RoomAllocation.t()]} | :insufficient
  def remove_amounts(_allocations, 0), do: {:ok, []}

  def remove_amounts(allocations, amount) do
    held = allocations |> Enum.map(& &1.amount_cents) |> Enum.sum()

    if held >= amount do
      touched =
        Enum.reduce_while(allocations, {amount, []}, fn allocation, {left, acc} ->
          take = min(allocation.amount_cents, left)

          if take == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - take)
            |> Repo.update!()
          end

          case left - take do
            0 -> {:halt, {[allocation | acc], 0}}
            rest -> {:cont, {rest, [allocation | acc]}}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      {:ok, touched}
    else
      :insufficient
    end
  end

  @doc """
  Deletes and returns the cash allocations held on the given rooms as
  `{source_operation_id, amount}` pairs in fill order.
  """
  @spec take_cash_allocations([Ecto.UUID.t()]) :: [{String.t() | nil, pos_integer()}]
  def take_cash_allocations(room_ids) do
    delete_allocations(room_ids, "cash")
    |> Enum.map(&{&1.source_operation_id, &1.amount_cents})
  end

  @doc """
  Deletes and returns the credit allocations held on the given rooms grouped by
  source lot as `{credit_lot_id, amount}` pairs.
  """
  @spec take_credit_allocations([Ecto.UUID.t()]) :: [{Ecto.UUID.t(), pos_integer()}]
  def take_credit_allocations(room_ids) do
    delete_allocations(room_ids, "credit")
    |> Enum.reduce(%{}, fn row, acc ->
      Map.update(acc, row.credit_lot_id, row.amount_cents, &(&1 + row.amount_cents))
    end)
    |> Enum.to_list()
  end

  defp delete_allocations(room_ids, funding_type) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.room_id in ^room_ids and a.funding_type == ^funding_type,
          order_by: [asc: a.fill_order]
      )

    Repo.delete_all(
      from a in RoomAllocation,
        where: a.room_id in ^room_ids and a.funding_type == ^funding_type
    )

    rows
  end

  defp room_capacities(group_id) do
    allocated = held_by_room(group_id)

    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: [asc: r.position]
    )
    |> Enum.map(&{&1.id, &1.deposit_cents - Map.get(allocated, &1.id, 0)})
  end

  defp held_by_room(group_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Map.new()
  end

  # Allocation order is globally monotonic so funding drawn across several
  # groups - after transfers, reductions, and chargebacks - has one
  # well-defined "most recently created first" order.
  defp next_fill_order do
    from(a in RoomAllocation)
    |> Repo.aggregate(:max, :fill_order)
    |> Kernel.||(0)
    |> Kernel.+(1)
  end
end
