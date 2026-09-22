defmodule GroupStay.Credits do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Credits.Lot
  alias GroupStay.Deposits
  alias GroupStay.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @bonus_percent 10
  @expires_after_days 366

  def issued_amount(0), do: 0

  def issued_amount(cash_cents) when is_integer(cash_cents) and cash_cents > 0 do
    cash_cents + Deposits.rounded_percent(cash_cents, @bonus_percent)
  end

  def summary(guest_id, as_of) when is_binary(guest_id) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &lot_map/1)
    }
  end

  def liability(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.remaining_cents > 0 and l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      )

    money(available) + money(applied)
  end

  def shortfall do
    Repo.all(from l in Lot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, acc ->
      acc + min(lot.unrecovered_clawback_cents, applied_to_active(lot.id))
    end)
  end

  def applied_by_room([]), do: %{}

  def applied_by_room(room_ids) do
    Repo.all(
      from a in Allocation,
        where: a.room_id in ^room_ids,
        group_by: a.room_id,
        select: {a.room_id, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  def consume(guest_id, %Group{} = group, amount, as_of)
      when is_binary(guest_id) and is_integer(amount) and amount > 0 do
    lots = available_lots(guest_id, as_of)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      assign_lots(lots, group, Funding.plan_fill(group, amount))
      :ok
    end
  end

  def issue_lot!(guest_id, source_operation_id, amount_cents, issued_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      original_cents: amount_cents,
      expires_on: Date.add(issued_on, @expires_after_days),
      issued_on: issued_on
    })
    |> Repo.insert!()
  end

  def restore_rooms!(group, room_ids, occurred_on) do
    allocations = allocations_for(group, room_ids)

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, rows} ->
      lot = Repo.get!(Lot, lot_id)
      amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
      restore_amount!(lot, amount, occurred_on)
    end)

    drop_rooms!(room_ids)
  end

  def drop_rooms!([]), do: :ok

  def drop_rooms!(room_ids) do
    Repo.delete_all(from a in Allocation, where: a.room_id in ^room_ids)
    :ok
  end

  def clawback!(_lot_id, entitlement) when entitlement <= 0, do: :ok

  def clawback!(lot_id, entitlement) do
    lot = Repo.get!(Lot, lot_id)
    removed = min(lot.remaining_cents, entitlement)

    lot
    |> Ecto.Changeset.change(%{
      remaining_cents: lot.remaining_cents - removed,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + (entitlement - removed)
    })
    |> Repo.update!()

    :ok
  end

  def place_existing!(group, chunks) do
    total = Enum.sum(Enum.map(chunks, &elem(&1, 1)))

    if total > 0 do
      assign_chunks(Funding.plan_fill(group, total), chunks, group)
    end

    :ok
  end

  defp assign_lots(lots, group, plan) do
    assign_available(lots, plan, group)
  end

  defp assign_available(_lots, [], _group), do: :ok

  defp assign_available([lot | lots], [{room, need} | needs], group) do
    take = min(lot.remaining_cents, need)

    lot =
      if take > 0 do
        insert_allocation!(group, room, lot, take)
        update_remaining!(lot, lot.remaining_cents - take)
      else
        lot
      end

    cond do
      need - take == 0 ->
        assign_available([lot | lots], needs, group)

      true ->
        assign_available(lots, [{room, need - take} | needs], group)
    end
  end

  defp assign_chunks([], [], _group), do: :ok

  defp assign_chunks([{room, need} | rooms], chunks, group) do
    {used, rest} = take_chunks(chunks, need)
    Enum.each(used, fn {lot_id, amount} -> insert_chunk!(group, room, lot_id, amount) end)
    assign_chunks(rooms, rest, group)
  end

  defp take_chunks(chunks, 0), do: {[], chunks}

  defp take_chunks([{lot_id, amount} | rest], need) when amount <= need do
    {taken, rest} = take_chunks(rest, need - amount)
    {[{lot_id, amount} | taken], rest}
  end

  defp take_chunks([{lot_id, amount} | rest], need) do
    {[{lot_id, need}], [{lot_id, amount - need} | rest]}
  end

  defp take_chunks([], need) when need > 0 do
    raise "credit chunks were short by #{need}"
  end

  defp available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id,
        where: l.remaining_cents > 0,
        where: l.expires_on > ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp allocations_for(_group, []), do: []

  defp allocations_for(group, room_ids) do
    Repo.all(
      from a in Allocation,
        where: a.group_id == ^group.id and a.room_id in ^room_ids
    )
  end

  defp restore_amount!(lot, amount, occurred_on) do
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    excess = amount - absorbed

    remaining =
      if unexpired?(lot.expires_on, occurred_on) do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    lot
    |> Ecto.Changeset.change(%{
      remaining_cents: remaining,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    })
    |> Repo.update!()
  end

  defp applied_to_active(lot_id) do
    Repo.one(
      from a in Allocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.credit_lot_id == ^lot_id and g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
    )
    |> money()
  end

  defp insert_allocation!(group, room, lot, amount) do
    insert_chunk!(group, room, lot.id, amount)
  end

  defp insert_chunk!(group, room, lot_id, amount) do
    %Allocation{}
    |> Allocation.changeset(%{
      group_id: group.id,
      room_id: room.id,
      credit_lot_id: lot_id,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp update_remaining!(lot, remaining) do
    lot
    |> Ecto.Changeset.change(%{remaining_cents: remaining})
    |> Repo.update!()
  end

  defp lot_map(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp unexpired?(expires_on, as_of), do: Date.compare(as_of, expires_on) == :lt

  defp money(value) when is_integer(value), do: value
  defp money(nil), do: 0
end
