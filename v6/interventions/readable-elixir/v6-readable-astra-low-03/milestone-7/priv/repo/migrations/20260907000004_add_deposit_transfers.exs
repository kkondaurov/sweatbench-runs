defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration
  import Ecto.Query

  def up do
    create table(:allocation_positions) do
    end

    alter table(:cash_allocations) do
      add :allocation_position, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_position, :integer
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    flush()
    backfill_positions()
  end

  def down do
    drop table(:transferred_payments)
    alter table(:credit_allocations), do: remove(:allocation_position)
    alter table(:cash_allocations), do: remove(:allocation_position)
    drop table(:allocation_positions)
  end

  # The former tables each had their own sequence. Recover interleaving from
  # committed funding operations, replaying room occupancy only (never money or
  # credit lots). Cancelled rooms and payment corrections matter because credit
  # allocation rows are deleted at settlement. Keep this migration independent
  # of application schemas and domain code.
  defp backfill_positions do
    records =
      repo().all(
        from(o in "operations",
          order_by: o.id,
          select: map(o, [:id, :operation_id, :operation_type, :submission, :result])
        )
      )
      |> Enum.map(&%{&1 | submission: decode(&1.submission), result: decode(&1.result)})
      |> Enum.filter(&(&1.result["status"] == "applied"))

    ranks = Map.new(records, &{&1.operation_id, &1.id})
    occupancy = Enum.reduce(records, legacy_occupancy(records), &replay/2)

    credit_blocks =
      for {group_id, rooms} <- occupancy,
          room <- rooms,
          block <- room.blocks,
          block.kind == :credit,
          reduce: %{} do
        acc -> Map.update(acc, {group_id, room.id}, [block], &(&1 ++ [block]))
      end

    groups = repo().all(from(g in "groups", select: map(g, [:group_id, :rooms])))

    room_order =
      for g <- groups,
          {room, index} <- Enum.with_index(decode(g.rooms)),
          into: %{},
          do: {{g.group_id, room["room_id"]}, index}

    cash =
      repo().all(
        from(a in "cash_allocations",
          order_by: a.id,
          select: map(a, [:id, :group_id, :room_id, :payment_operation_id])
        )
      )

    credit =
      repo().all(
        from(a in "credit_allocations",
          order_by: a.id,
          select: map(a, [:id, :group_id, :room_id, :amount_cents])
        )
      )

    cash_positions =
      Enum.map(cash, fn a ->
        rank = Map.get(ranks, a.payment_operation_id, 0)

        {"cash_allocations", a.id,
         {rank, Map.get(room_order, {a.group_id, a.room_id}, 0), 0, a.id}}
      end)

    {credit_positions, _} =
      Enum.map_reduce(credit, credit_blocks, fn a, blocks ->
        key = {a.group_id, a.room_id}
        {rank, remaining} = take_block(Map.get(blocks, key, []), a.amount_cents)

        {{"credit_allocations", a.id, {rank, Map.get(room_order, key, 0), 1, a.id}},
         Map.put(blocks, key, remaining)}
      end)

    (cash_positions ++ credit_positions)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.with_index(1)
    |> Enum.each(fn {{table, id, _}, position} ->
      repo().insert_all("allocation_positions", [%{id: position}])

      repo().update_all(from(a in table, where: a.id == ^id),
        set: [allocation_position: position]
      )
    end)
  end

  defp legacy_occupancy(records) do
    opened = for r <- records, r.operation_type == "open_group", do: r.result["group_id"]
    groups = repo().all(from(g in "groups", select: map(g, [:group_id, :rooms])))

    for group <- groups, group.group_id not in opened, into: %{} do
      rooms =
        Enum.map(decode(group.rooms), fn room ->
          %{id: room["room_id"], due: room["deposit_due_cents"], active: true, blocks: []}
        end)

      cash =
        repo().one(
          from(a in "cash_allocations",
            where: a.group_id == ^group.group_id and is_nil(a.payment_operation_id),
            select: coalesce(sum(a.amount_cents), 0)
          )
        )

      credit =
        repo().one(
          from(a in "credit_allocations",
            where: a.group_id == ^group.group_id,
            select: coalesce(sum(a.amount_cents), 0)
          )
        )

      applications =
        records
        |> Enum.filter(
          &(&1.result["group_id"] == group.group_id and &1.operation_type == "apply_hotel_credit")
        )

      legacy_credit =
        max(0, credit - Enum.sum(Enum.map(applications, & &1.result["amount_cents"])))

      # The first funding result also captures the pre-operation aggregate. Use
      # it when available so later room cancellations cannot hide senior credit.
      first_financial =
        Enum.find(records, fn record ->
          record.result["group_id"] == group.group_id and
            record.operation_type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "cancel_group",
              "cancel_rooms"
            ]
        end)

      legacy_credit =
        case first_financial do
          %{
            operation_type: type,
            result: %{"outstanding_deposit_cents" => outstanding, "amount_cents" => amount}
          }
          when type in ["record_cash_payment", "apply_hotel_credit"] ->
            max(0, Enum.sum(Enum.map(rooms, & &1.due)) - outstanding - amount - cash)

          _ ->
            legacy_credit
        end

      rooms = fill_rooms(rooms, cash, :cash, nil, 0)
      {group.group_id, fill_rooms(rooms, legacy_credit, :credit, nil, 0)}
    end
  end

  defp fill_rooms(rooms, amount, kind, payment, rank) do
    {rooms, _} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        held = Enum.sum(Enum.map(room.blocks, & &1.amount))
        used = if room.active, do: min(needed, room.due - held), else: 0
        block = %{kind: kind, payment: payment, rank: rank, amount: used}
        {if(used > 0, do: %{room | blocks: room.blocks ++ [block]}, else: room), needed - used}
      end)

    rooms
  end

  defp take_block([], _amount), do: {0, []}

  defp take_block([block | rest], amount) do
    remaining =
      if amount >= block.amount, do: rest, else: [%{block | amount: block.amount - amount} | rest]

    {block.rank, remaining}
  end

  defp replay(record, groups) do
    op = record.submission
    id = record.result["group_id"]
    rooms = Map.get(groups, id)

    cond do
      record.operation_type == "open_group" ->
        nights =
          Date.diff(Date.from_iso8601!(op["departure_on"]), Date.from_iso8601!(op["arrival_on"]))

        rooms =
          Enum.map(op["rooms"], fn room ->
            lodging = nights * room["nightly_rate_cents"]
            due = if op["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
            %{id: room["room_id"], due: due, active: true, blocks: []}
          end)

        Map.put(groups, id, rooms)

      is_nil(rooms) ->
        groups

      record.operation_type in ["record_cash_payment", "apply_hotel_credit"] ->
        kind = if record.operation_type == "record_cash_payment", do: :cash, else: :credit

        rooms =
          fill_rooms(rooms, record.result["amount_cents"], kind, record.operation_id, record.id)

        Map.put(groups, id, rooms)

      record.operation_type in ["cancel_group", "cancel_rooms"] ->
        rooms =
          Enum.map(rooms, fn room ->
            if record.operation_type == "cancel_group" or room.id in op["room_ids"],
              do: %{room | active: false, blocks: []},
              else: room
          end)

        Map.put(groups, id, rooms)

      record.operation_type in ["reduce_cash_payment", "charge_back_payment"] ->
        amount = record.result["amount_cents"] || record.result["charged_back_cents"]

        {rooms, _} =
          Enum.map_reduce(Enum.reverse(rooms), amount, fn room, needed ->
            {blocks, needed} =
              Enum.map_reduce(Enum.reverse(room.blocks), needed, fn block, left ->
                removed =
                  if block.kind == :cash and block.payment == op["payment_operation_id"],
                    do: min(left, block.amount),
                    else: 0

                {%{block | amount: block.amount - removed}, left - removed}
              end)

            {%{room | blocks: Enum.reverse(blocks)}, needed}
          end)

        Map.put(groups, id, Enum.reverse(rooms))

      true ->
        groups
    end
  end

  defp decode(value) when is_binary(value), do: value |> Jason.decode!() |> decode()
  defp decode(value) when is_list(value), do: Enum.map(value, &decode/1)
  defp decode(value), do: value
end
