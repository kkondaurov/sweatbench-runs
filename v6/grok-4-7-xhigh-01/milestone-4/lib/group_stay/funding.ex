defmodule GroupStay.Funding do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Deposits
  alias GroupStay.Funding.CashAllocation
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
          where: a.operation_id == ^operation_id and a.disposition == "held",
          order_by: [desc: a.sequence, desc: a.id]
      )

    reduce_rows(rows, amount)
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
      clawbacks: clawbacks
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
          sequence: Enum.min(Enum.map(group_rows, & &1.sequence)),
          principal: sum_amounts(group_rows)
        }
      end)
      |> Enum.sort_by(&{&1.sequence, &1.operation_id || ""})

    {found, _running, _prev} =
      Enum.reduce(contributions, {0, 0, 0}, fn contrib, {found, running, prev} ->
        running = running + contrib.principal
        value = issued_amount(running)
        found = if contrib.operation_id == operation_id, do: value - prev, else: found
        {found, running, value}
      end)

    found
  end

  defp reduce_rows(_rows, 0), do: :ok

  defp reduce_rows([row | rest], left) do
    take = min(left, row.amount_cents)

    cond do
      take == row.amount_cents ->
        row
        |> Ecto.Changeset.change(%{disposition: "reduced"})
        |> Repo.update!()

      take > 0 ->
        row
        |> Ecto.Changeset.change(%{amount_cents: row.amount_cents - take})
        |> Repo.update!()

        insert_cash!(%{
          group_id: row.group_id,
          room_id: row.room_id,
          operation_id: row.operation_id,
          amount_cents: take,
          sequence: row.sequence,
          disposition: "reduced"
        })
    end

    reduce_rows(rest, left - take)
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
    |> CashAllocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp sum_amounts(rows, disposition) do
    rows
    |> Enum.filter(&(&1.disposition == disposition))
    |> sum_amounts()
  end

  defp sum_amounts(rows), do: Enum.sum(Enum.map(rows, & &1.amount_cents))
end
