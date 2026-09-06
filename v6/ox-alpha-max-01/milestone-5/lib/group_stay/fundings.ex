defmodule GroupStay.Fundings do
  @moduledoc """
  Allocates cash and hotel credit across a group's active rooms.

  Funding fills active rooms in their original order, exhausting one room's
  deposit requirement before moving to the next. The unattributed senior
  block brought forward from before durable operation records was allocated
  first at migration time; every later operation appends its allocations,
  so insertion order is the funding order used across the service.

  Allocations are the source of truth for held amounts: group totals,
  outstanding deposits, ledger `cash_held_cents`, and per-payment
  reconciliation all read them back.
  """

  import Ecto.Query

  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @doc """
  The group's active rooms in their original order.
  """
  def active_rooms(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active",
      order_by: r.position
    )
    |> Repo.all()
  end

  @doc """
  Every room of the group in its original order, whatever its status.
  """
  def rooms(group_id) do
    from(r in Room, where: r.group_id == ^group_id, order_by: r.position) |> Repo.all()
  end

  @doc """
  Each active room with its still-unfunded deposit capacity, in fill order.
  """
  def room_capacities(%Group{} = group) do
    paid = held_per_room(group.id)

    active_rooms(group.id)
    |> Enum.map(fn room ->
      used = used_cents(paid, room.id)

      %{
        room: room,
        capacity: max((room.deposit_due_cents || 0) - used.cash - used.credit, 0)
      }
    end)
  end

  @doc """
  Spreads `amount_cents` of one cash payment across the group's active
  rooms in fill order. Returns the inserted funding rows.
  """
  def allocate_cash(%Group{} = group, amount_cents, operation_id) do
    spread(group, [
      %{kind: "cash", operation_id: operation_id, credit_lot_id: nil, amount: amount_cents}
    ])
  end

  @doc """
  Spreads redeemed hotel credit across the group's active rooms in fill
  order. `chunks` carry the consumed lot and owning operation per slice, in
  lot-consumption order. Returns the inserted funding rows.
  """
  def allocate_credit(%Group{} = group, chunks) do
    chunks =
      Enum.map(chunks, fn chunk ->
        %{
          kind: "credit",
          operation_id: chunk.operation_id,
          credit_lot_id: chunk.credit_lot_id,
          amount: chunk.amount
        }
      end)

    spread(group, chunks)
  end

  @doc """
  Draws `amount_cents` of a group's held funding — cash and credit alike,
  whatever their provenance — in reverse allocation order (the most
  recently created allocation first), deleting fully drawn fundings and
  shrinking partially drawn ones.

  Returns `{amount_taken, funding}` pairs in draw order. The caller reinserts
  them elsewhere unchanged so each moved slice keeps its provenance.
  """
  def draw_held_funding(group_id, amount_cents) do
    fundings =
      from(f in Funding, where: f.group_id == ^group_id, order_by: [desc: f.id])
      |> Repo.all()

    {drawn, leftover} =
      Enum.reduce(fundings, {[], amount_cents}, fn funding, acc ->
        {pairs, remaining} = acc

        if remaining <= 0 do
          acc
        else
          take = min(funding.amount_cents, remaining)

          if take == funding.amount_cents do
            Repo.delete!(funding)
          else
            {:ok, _} =
              funding
              |> Funding.changeset(%{amount_cents: funding.amount_cents - take})
              |> Repo.update()
          end

          {[{take, funding} | pairs], remaining - take}
        end
      end)

    if leftover != 0 do
      raise "group #{inspect(group_id)} held less funding than the draw requested"
    end

    Enum.reverse(drawn)
  end

  @doc """
  Fills previously drawn slices into a group's active rooms in their
  original order, preserving the order in which the units were drawn. Every
  inserted row keeps its provenance — kind, funding operation, and credit
  lot.
  """
  def fill_from_drawn(%Group{} = group, drawn) do
    chunks =
      Enum.map(drawn, fn {taken, funding} ->
        %{
          kind: funding.kind,
          operation_id: funding.operation_id,
          credit_lot_id: funding.credit_lot_id,
          amount: taken
        }
      end)

    spread(group, chunks)
  end

  @doc """
  Held funding sums per room id: `%{room_id => %{cash: n, credit: n}}`.
  """
  def held_per_room(group_id) do
    from(f in Funding,
      where: f.group_id == ^group_id,
      group_by: [f.room_id, f.kind],
      select: {f.room_id, f.kind, coalesce(sum(f.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {room_id, kind, sum}, acc ->
      acc
      |> Map.put_new(room_id, %{cash: 0, credit: 0})
      |> put_in([Access.key(room_id), Access.key(String.to_existing_atom(kind))], sum)
    end)
  end

  @doc """
  Cash currently held on the group's active rooms, regardless of which
  payment it came from.
  """
  def group_held_cents(group_id, kind \\ "cash") do
    from(f in Funding,
      where: f.group_id == ^group_id and f.kind == ^kind,
      select: coalesce(sum(f.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Cash from one recorded payment still allocated to live room fundings.
  """
  def payment_held_cents(operation_id) do
    from(f in Funding,
      where: f.operation_id == ^operation_id and f.kind == "cash",
      select: coalesce(sum(f.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  One payment's held cash grouped by owning group, ordered by partner group
  id: the `held_by_group` statement entries.
  """
  def payment_held_by_group(operation_id) do
    from(f in Funding,
      join: g in Group,
      on: g.id == f.group_id,
      where: f.operation_id == ^operation_id and f.kind == "cash",
      group_by: g.group_id,
      order_by: g.group_id,
      select: {g.group_id, coalesce(sum(f.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.reject(fn {_group_id, cents} -> cents == 0 end)
    |> Enum.map(fn {group_id, cents} -> %{"group_id" => group_id, "amount_cents" => cents} end)
  end

  @doc """
  Removes `amount_cents` of a payment's held cash in reverse fill order, so
  the most recently funded positions give way first — across every group
  the payment currently funds. The caller validates the amount against the
  payment's held cash beforehand. Returns the distinct internal group ids
  whose allocations were touched.
  """
  def remove_payment_cash(operation_id, amount_cents) do
    fundings =
      from(f in Funding,
        where: f.operation_id == ^operation_id and f.kind == "cash",
        order_by: [desc: f.id]
      )
      |> Repo.all()

    {touched, leftover} =
      Enum.reduce(fundings, {[], amount_cents}, fn funding, acc ->
        {touched, remaining} = acc

        if remaining <= 0 do
          acc
        else
          take = min(funding.amount_cents, remaining)

          if take == funding.amount_cents do
            Repo.delete!(funding)
          else
            {:ok, _} =
              funding
              |> Funding.changeset(%{amount_cents: funding.amount_cents - take})
              |> Repo.update()
          end

          {[funding.group_id | touched], remaining - take}
        end
      end)

    if leftover != 0 do
      raise "payment #{inspect(operation_id)} held less cash than the removal requested"
    end

    Enum.uniq(Enum.reverse(touched))
  end

  @doc """
  All cash fundings of the given rooms in fill order — the basis for
  settling selected rooms and attributing dispositions to payments.
  """
  def cash_fundings_for_rooms(room_ids) do
    from(f in Funding,
      where: f.room_id in ^room_ids and f.kind == "cash",
      order_by: [asc: f.id]
    )
    |> Repo.all()
  end

  @doc """
  All credit fundings of the given rooms in fill order.
  """
  def credit_fundings_for_rooms(room_ids) do
    from(f in Funding,
      where: f.room_id in ^room_ids and f.kind == "credit",
      order_by: [asc: f.id]
    )
    |> Repo.all()
  end

  @doc """
  Credit currently applied to active groups across all room fundings.
  """
  def applied_to_active_groups do
    from(f in Funding,
      join: g in Group,
      on: g.id == f.group_id,
      where: f.kind == "credit" and g.status == "active",
      select: coalesce(sum(f.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Credit from one lot still applied to active groups.
  """
  def lot_applied_to_active_groups(lot_id) do
    from(f in Funding,
      join: g in Group,
      on: g.id == f.group_id,
      where: f.credit_lot_id == ^lot_id and f.kind == "credit" and g.status == "active",
      select: coalesce(sum(f.amount_cents), 0)
    )
    |> Repo.one()
  end

  # Fills the group's active rooms from successive chunks, each carrying its
  # own kind and provenance: one room fills completely before the next, and
  # earlier-drawn units land in earlier rooms.
  defp spread(%Group{} = group, chunks) do
    capacities = room_capacities(group)

    spread_rows(capacities, chunks, [])
    |> Enum.map(fn {room, take, chunk} ->
      insert!(%{
        group_id: group.id,
        room_id: room.id,
        kind: chunk.kind,
        operation_id: chunk.operation_id,
        credit_lot_id: chunk.credit_lot_id,
        amount_cents: take
      })
    end)
  end

  defp spread_rows(_capacities, [], acc), do: Enum.reverse(acc)

  defp spread_rows([], _chunks, acc), do: Enum.reverse(acc)

  defp spread_rows(capacities, [%{amount: amount} | rest], acc) when amount <= 0 do
    spread_rows(capacities, rest, acc)
  end

  defp spread_rows([%{capacity: 0} | rest], chunks, acc),
    do: spread_rows(rest, chunks, acc)

  defp spread_rows(
         [%{room: room, capacity: capacity} | rest_rooms],
         [chunk | rest_chunks],
         acc
       ) do
    take = min(chunk.amount, capacity)

    spread_rows(
      [%{room: room, capacity: capacity - take} | rest_rooms],
      [%{chunk | amount: chunk.amount - take} | rest_chunks],
      [{room, take, chunk} | acc]
    )
  end

  defp insert!(attrs) do
    {:ok, funding} =
      %Funding{}
      |> Funding.changeset(attrs)
      |> Repo.insert()

    funding
  end

  defp used_cents(paid, room_id) do
    Map.get(paid, room_id, %{cash: 0, credit: 0})
  end
end
