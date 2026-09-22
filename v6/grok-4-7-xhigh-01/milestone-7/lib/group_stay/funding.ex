defmodule GroupStay.Funding do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Deposits
  alias GroupStay.Funding.CashAllocation
  alias GroupStay.Funding.TransferredPayment
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @dispositions ~w(held refunded retained converted reduced charged_back)

  def active_rooms(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: [asc: r.position, asc: r.id]
    )
  end

  def all_rooms(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id,
        order_by: [asc: r.position, asc: r.id]
    )
  end

  def plan_fill(group, amount) when is_integer(amount) and amount >= 0 do
    rooms = active_rooms(group)
    funded = funded_by_room(Enum.map(rooms, & &1.id))

    {plan, left} =
      Enum.reduce(rooms, {[], amount}, fn room, {plan, left} ->
        space = max((room.deposit_due_cents || 0) - Map.get(funded, room.id, 0), 0)
        take = min(space, left)

        if take > 0 do
          {[{room, take} | plan], left - take}
        else
          {plan, left}
        end
      end)

    if left != 0 do
      raise "could not allocate #{amount} cents across active rooms of #{group.group_id}"
    end

    Enum.reverse(plan)
  end

  def allocate_cash!(group, operation_id, amount) when is_integer(amount) and amount > 0 do
    plan = plan_fill(group, amount)
    sequence = next_sequence(group.id)

    Enum.reduce(plan, sequence, fn {room, take}, seq ->
      insert_cash!(%{
        group_id: group.id,
        room_id: room.id,
        operation_id: operation_id,
        amount_cents: take,
        sequence: seq,
        disposition: "held"
      })

      seq + 1
    end)

    :ok
  end

  def allocate_cash!(_group, _operation_id, 0), do: :ok

  def held_funding(group) do
    ids = Enum.map(active_rooms(group), & &1.id)
    held_cash_total(ids) + applied_credit_total(ids)
  end

  def available_deposit(group) do
    rooms = active_rooms(group)
    funded = funded_by_room(Enum.map(rooms, & &1.id))

    Enum.reduce(rooms, 0, fn room, acc ->
      acc + max((room.deposit_due_cents || 0) - Map.get(funded, room.id, 0), 0)
    end)
  end

  def transfer_held!(source, destination, amount) when is_integer(amount) and amount > 0 do
    drawn = draw_held!(source, amount)
    :ok = place_drawn!(destination, drawn)
    mark_moved_payments!(drawn)

    drawn
    |> Enum.filter(&(&1.kind == :cash))
    |> Enum.reduce(0, fn unit, sum -> sum + unit.amount end)
  end

  def transfer_participated?(operation_id) when is_binary(operation_id) do
    Repo.exists?(from t in TransferredPayment, where: t.operation_id == ^operation_id)
  end

  def held_by_group(operation_id) when is_binary(operation_id) do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.operation_id == ^operation_id and a.disposition == "held",
        group_by: g.group_id,
        select: {g.group_id, sum(a.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount} ->
      %{group_id: group_id, amount_cents: amount || 0}
    end)
    |> Enum.filter(&(&1.amount_cents > 0))
    |> Enum.sort_by(& &1.group_id)
  end

  def order_ready? do
    case :persistent_term.get({__MODULE__, :order_ready}, false) do
      true ->
        true

      false ->
        ready = cash_order_column?()
        if ready, do: :persistent_term.put({__MODULE__, :order_ready}, true)
        ready
    end
  end

  def reserve_order!(amount) when is_integer(amount) and amount > 0 do
    next_order_lo()
  end

  def held_cash_by_room([]), do: %{}

  def held_cash_by_room(room_ids) do
    Repo.all(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.disposition == "held",
        group_by: a.room_id,
        select: {a.room_id, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  def held_cash_total([]), do: 0

  def held_cash_total(room_ids) do
    Repo.one(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.disposition == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  def held_for_operation(operation_id) do
    Repo.one(
      from a in CashAllocation,
        where: a.operation_id == ^operation_id and a.disposition == "held",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  def charged_back?(operation_id) do
    Repo.exists?(
      from a in CashAllocation,
        where: a.operation_id == ^operation_id and a.disposition == "charged_back"
    )
  end

  def chargeable_cents(operation_id) do
    Repo.one(
      from a in CashAllocation,
        where: a.operation_id == ^operation_id and a.disposition != "reduced",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  def dispositions(operation_id) do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.operation_id == ^operation_id,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(@dispositions, fn disposition ->
      {disposition, Map.get(rows, disposition, 0)}
    end)
  end

  def sum_disposition(disposition) do
    Repo.one(
      from a in CashAllocation,
        where: a.disposition == ^disposition,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  def reclassify_held!(room_ids, disposition, credit_lot_id \\ nil)

  def reclassify_held!(_room_ids, nil, _credit_lot_id), do: :ok
  def reclassify_held!([], _disposition, _credit_lot_id), do: :ok

  def reclassify_held!(room_ids, disposition, credit_lot_id) do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.room_id in ^room_ids and a.disposition == "held"
      )

    Enum.each(rows, fn row ->
      changes = %{disposition: disposition}

      changes =
        if credit_lot_id, do: Map.put(changes, :credit_lot_id, credit_lot_id), else: changes

      row
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    end)

    :ok
  end

  def reclassify_group_held!(group_id, disposition, credit_lot_id \\ nil) do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group_id and a.disposition == "held"
      )

    Enum.each(rows, fn row ->
      changes = %{disposition: disposition}

      changes =
        if credit_lot_id, do: Map.put(changes, :credit_lot_id, credit_lot_id), else: changes

      row
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    end)

    :ok
  end

  def cancel_rooms!([]), do: :ok

  def cancel_rooms!(room_ids) do
    Repo.update_all(from(r in Room, where: r.id in ^room_ids), set: [status: "cancelled"])
    :ok
  end

  def mark_rooms!(group, status) do
    Repo.update_all(from(r in Room, where: r.group_id == ^group.id), set: [status: status])
    :ok
  end

  def reduce_held!(operation_id, amount) when is_integer(amount) and amount > 0 do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.operation_id == ^operation_id and a.disposition == "held"
      )
      |> newest_first()

    reduce_rows(rows, amount, [])
  end

  def charge_back!(operation_id) do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.operation_id == ^operation_id and a.disposition != "reduced"
      )

    clawbacks =
      rows
      |> Enum.map(& &1.credit_lot_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn lot_id -> {lot_id, entitlement(lot_id, operation_id)} end)

    Enum.each(rows, fn row ->
      row
      |> Ecto.Changeset.change(%{disposition: "charged_back"})
      |> Repo.update!()
    end)

    %{
      charged_back_cents: sum_amounts(rows),
      refunded_cents: sum_amounts(rows, "refunded"),
      retained_cents: sum_amounts(rows, "retained"),
      converted_cents: sum_amounts(rows, "converted"),
      clawbacks: clawbacks,
      per_group: disposition_by_group(rows)
    }
  end

  def entitlement(lot_id, operation_id) do
    rows =
      Repo.all(
        from a in CashAllocation,
          where: a.credit_lot_id == ^lot_id,
          order_by: [asc: a.sequence, asc: a.id]
      )

    contributions =
      rows
      |> Enum.group_by(& &1.operation_id)
      |> Enum.map(fn {op_id, group_rows} ->
        %{
          operation_id: op_id,
          order_lo: Enum.min(Enum.map(group_rows, &(&1.order_lo || 0))),
          sequence: Enum.min(Enum.map(group_rows, & &1.sequence)),
          principal: sum_amounts(group_rows)
        }
      end)
      |> Enum.sort_by(&{&1.order_lo, &1.sequence, &1.operation_id || ""})

    {found, _running, _prev} =
      Enum.reduce(contributions, {0, 0, 0}, fn contrib, {found, running, prev} ->
        running = running + contrib.principal
        value = issued_amount(running)
        found = if contrib.operation_id == operation_id, do: value - prev, else: found
        {found, running, value}
      end)

    found
  end

  defp reduce_rows(_rows, 0, groups), do: Enum.reverse(groups)

  defp reduce_rows([], left, _groups) when left > 0 do
    raise "held cash was short by #{left}"
  end

  defp reduce_rows([row | rest], left, groups) do
    take = min(left, row.amount_cents)
    reduce_row(row, take)

    reduce_rows(rest, left - take, [
      %{group_id: row.group_id, amount_cents: take} | groups
    ])
  end

  defp reduce_row(row, take) when take == row.amount_cents do
    row
    |> Ecto.Changeset.change(%{disposition: "reduced"})
    |> Repo.update!()
  end

  defp reduce_row(row, take) when take > 0 do
    remainder = row.amount_cents - take

    row
    |> Ecto.Changeset.change(%{amount_cents: remainder})
    |> Repo.update!()

    insert_cash!(%{
      group_id: row.group_id,
      room_id: row.room_id,
      operation_id: row.operation_id,
      credit_lot_id: row.credit_lot_id,
      amount_cents: take,
      sequence: row.sequence,
      order_lo: (row.order_lo || 0) + remainder,
      disposition: "reduced"
    })
  end

  defp funded_by_room([]), do: %{}

  defp funded_by_room(room_ids) do
    cash = held_cash_by_room(room_ids)
    credit = applied_credit_by_room(room_ids)

    Map.merge(cash, credit, fn _id, left, right -> left + right end)
  end

  defp next_sequence(group_id) do
    max =
      Repo.one(
        from a in CashAllocation,
          where: a.group_id == ^group_id,
          select: max(a.sequence)
      ) || 0

    max + 1
  end

  defp applied_credit_by_room(room_ids) do
    Repo.all(
      from a in Allocation,
        where: a.room_id in ^room_ids,
        group_by: a.room_id,
        select: {a.room_id, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp issued_amount(0), do: 0

  defp issued_amount(cash_cents) when is_integer(cash_cents) and cash_cents > 0 do
    cash_cents + Deposits.rounded_percent(cash_cents, 10)
  end

  defp insert_cash!(attrs) do
    %CashAllocation{}
    |> CashAllocation.changeset(assign_order(attrs))
    |> Repo.insert!()
  end

  defp assign_order(attrs) do
    cond do
      not order_ready?() ->
        Map.delete(attrs, :order_lo)

      is_integer(attrs[:order_lo]) ->
        attrs

      true ->
        Map.put(attrs, :order_lo, reserve_order!(attrs.amount_cents))
    end
  end

  defp draw_held!(group, amount) do
    drawn = take_units(newest_first(held_units(group)), amount, [])
    drawn_total = Enum.sum(Enum.map(drawn, & &1.amount))

    if drawn_total != amount do
      raise "transfer draw accounted for #{drawn_total} of #{amount}"
    end

    drawn
  end

  defp take_units(_units, 0, drawn), do: drawn

  defp take_units([unit | rest], left, drawn) when left > 0 do
    take = min(left, unit.amount_cents)
    moved = detach_high!(unit, take)
    take_units(rest, left - take, drawn ++ [moved])
  end

  defp take_units([], left, _drawn) when left > 0 do
    raise "held funding was short by #{left}"
  end

  defp detach_high!(unit, take) do
    order_lo = unit.order_lo || 0
    high_lo = order_lo + unit.amount_cents - take
    remainder = unit.amount_cents - take

    if remainder == 0 do
      Repo.delete!(unit.row)
    else
      unit.row
      |> Ecto.Changeset.change(%{amount_cents: remainder})
      |> Repo.update!()
    end

    %{
      kind: unit.kind,
      order_lo: high_lo,
      amount: take,
      operation_id: Map.get(unit, :operation_id),
      sequence: Map.get(unit, :sequence),
      credit_lot_id: Map.get(unit, :credit_lot_id)
    }
  end

  defp place_drawn!(group, drawn) do
    total = Enum.sum(Enum.map(drawn, & &1.amount))
    place_units(drawn, plan_fill(group, total), group)
  end

  defp place_units([], [], _group), do: :ok

  defp place_units([unit | units], [{room, need} | rooms], group) do
    take = min(unit.amount, need)
    high_lo = unit.order_lo + unit.amount - take
    insert_moved!(group, room, unit, high_lo, take)

    units =
      if unit.amount > take do
        [%{unit | amount: unit.amount - take} | units]
      else
        units
      end

    rooms =
      if need > take do
        [{room, need - take} | rooms]
      else
        rooms
      end

    place_units(units, rooms, group)
  end

  defp insert_moved!(group, room, %{kind: :cash} = unit, order_lo, amount) do
    insert_cash!(%{
      group_id: group.id,
      room_id: room.id,
      operation_id: unit.operation_id,
      credit_lot_id: unit.credit_lot_id,
      amount_cents: amount,
      sequence: unit.sequence,
      disposition: "held",
      order_lo: order_lo
    })
  end

  defp insert_moved!(group, room, %{kind: :credit} = unit, order_lo, amount) do
    %Allocation{}
    |> Allocation.changeset(%{
      group_id: group.id,
      room_id: room.id,
      credit_lot_id: unit.credit_lot_id,
      amount_cents: amount,
      order_lo: order_lo
    })
    |> Repo.insert!()
  end

  defp mark_moved_payments!(units) do
    units
    |> Enum.filter(&(&1.kind == :cash and is_binary(&1.operation_id) and &1.operation_id != ""))
    |> Enum.map(& &1.operation_id)
    |> Enum.uniq()
    |> Enum.each(&insert_transfer_mark!/1)
  end

  defp insert_transfer_mark!(operation_id) do
    if transfer_participated?(operation_id) do
      :ok
    else
      Repo.insert!(%TransferredPayment{operation_id: operation_id})
    end
  end

  defp held_units(group) do
    room_ids = Enum.map(active_rooms(group), & &1.id)
    held_cash_units(room_ids) ++ held_credit_units(room_ids)
  end

  defp held_cash_units([]), do: []

  defp held_cash_units(room_ids) do
    Repo.all(
      from a in CashAllocation,
        where: a.room_id in ^room_ids and a.disposition == "held"
    )
    |> Enum.map(fn row ->
      %{
        kind: :cash,
        row: row,
        amount_cents: row.amount_cents,
        order_lo: row.order_lo,
        operation_id: row.operation_id,
        sequence: row.sequence,
        credit_lot_id: row.credit_lot_id
      }
    end)
  end

  defp held_credit_units([]), do: []

  defp held_credit_units(room_ids) do
    Repo.all(from a in Allocation, where: a.room_id in ^room_ids)
    |> Enum.map(fn row ->
      %{
        kind: :credit,
        row: row,
        amount_cents: row.amount_cents,
        order_lo: row.order_lo,
        credit_lot_id: row.credit_lot_id
      }
    end)
  end

  defp newest_first(rows) do
    Enum.sort_by(rows, &allocation_rank/1, :desc)
  end

  defp allocation_rank(%{amount_cents: amount, order_lo: order_lo} = row) do
    {(order_lo || 0) + amount, Map.get(row, :sequence) || 0, row_id(row)}
  end

  defp row_id(%{row: %{id: id}}), do: id
  defp row_id(%{id: id}), do: id

  defp disposition_by_group(rows) do
    rows
    |> Enum.group_by(& &1.group_id)
    |> Map.new(fn {group_id, grows} ->
      {group_id,
       %{
         held_cents: sum_amounts(grows, "held"),
         refunded_cents: sum_amounts(grows, "refunded"),
         retained_cents: sum_amounts(grows, "retained"),
         converted_cents: sum_amounts(grows, "converted")
       }}
    end)
  end

  defp applied_credit_total([]), do: 0

  defp applied_credit_total(room_ids) do
    Repo.one(
      from a in Allocation,
        where: a.room_id in ^room_ids,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp next_order_lo do
    max(max_order_hi(CashAllocation), max_order_hi(Allocation)) + 1
  end

  defp max_order_hi(schema) do
    Repo.one(
      from a in schema,
        select: max(fragment("COALESCE(?, 0) + ? - 1", a.order_lo, a.amount_cents))
    ) || 0
  end

  defp cash_order_column? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pragma_table_info('cash_allocations') WHERE name = 'order_lo' LIMIT 1"
      )

    rows != []
  end

  defp sum_amounts(rows, disposition) do
    rows
    |> Enum.filter(&(&1.disposition == disposition))
    |> sum_amounts()
  end

  defp sum_amounts(rows), do: Enum.sum(Enum.map(rows, & &1.amount_cents))
end
