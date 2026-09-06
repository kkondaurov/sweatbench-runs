defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.Groups.{CreditLot, Group, Room, RoomCashAllocation, RoomCreditApplication}
  alias GroupStay.Operations.Record

  def up do
    alter table(:group_rooms, primary_key: false) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer
      add :deposit_due_cents, :integer
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots, primary_key: false) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all)

      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false, default: "held"
      add :credit_lot_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:room_cash_allocations, [:payment_operation_id])
    create index(:room_cash_allocations, [:group_id])

    create table(:room_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :applied_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:room_credit_applications, [:room_id, :credit_lot_id])
    create index(:room_credit_applications, [:credit_lot_id])

    flush()

    repo().all(from(g in Group, order_by: g.id))
    |> Enum.each(&backfill_group/1)

    drop table(:group_credit_applications)
  end

  def down do
    create table(:group_credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :applied_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_credit_applications, [:group_id, :credit_lot_id])

    drop table(:room_credit_applications)
    drop table(:room_cash_allocations)

    alter table(:credit_lots, primary_key: false) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms, primary_key: false) do
      remove :status
      remove :lodging_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  defp backfill_group(group) do
    rooms =
      repo().all(from(r in Room, where: r.group_id == ^group.id, order_by: r.position))
      |> Enum.map(fn room ->
        lodging = room.nightly_rate_cents * Date.diff(group.departure_on, group.arrival_on)

        room
        |> Ecto.Changeset.change(%{
          status: if(group.status == "cancelled", do: "cancelled", else: "active"),
          lodging_cents: lodging,
          deposit_due_cents: room_deposit(lodging, group.rate_plan)
        })
        |> repo().update!()
      end)

    case rooms do
      [] ->
        :ok

      _ ->
        if group.status == "active" do
          items = active_funding_timeline(group)

          placed =
            Enum.reduce(items, rooms, fn item, acc_rooms ->
              place_item(repo(), group, item, acc_rooms)
            end)

          sync_group_columns!(group.id, placed)
        else
          record_settled_dispositions!(group, rooms)
        end
    end
  end

  # Funding is replayed as one timeline per group: the unattributed legacy
  # block first (aggregate cash, then credit lots in their original consumption
  # order), then applied cash payments and credit applications in durable-record
  # commit order regardless of occurred_on.
  defp active_funding_timeline(group) do
    ops = applied_group_operations(group)

    legacy_cash =
      max(0, group.cash_paid_cents - total(ops, :cash))

    legacy_credit_total =
      max(0, group.credit_paid_cents - total(ops, :credit))

    application_queue =
      repo().all(
        from(a in "group_credit_applications",
          where: a.group_id == ^group.id,
          order_by: [asc: a.inserted_at, asc: a.credit_lot_id],
          select: %{credit_lot_id: a.credit_lot_id, amount: a.applied_cents}
        )
      )

    {legacy_items, queue} = take_from_queue(application_queue, legacy_credit_total, [])

    legacy =
      [%{kind: :cash, payment_operation_id: nil, credit_lot_id: nil, amount: legacy_cash}] ++
        Enum.map(legacy_items, fn item ->
          %{
            kind: :credit,
            payment_operation_id: nil,
            credit_lot_id: item.credit_lot_id,
            amount: item.amount
          }
        end)

    {durable, _queue} =
      Enum.flat_map_reduce(ops, queue, fn op, acc ->
        case op.type do
          :cash ->
            {[
               %{
                 kind: :cash,
                 payment_operation_id: op.operation_id,
                 credit_lot_id: nil,
                 amount: op.amount
               }
             ], acc}

          :credit ->
            {items, rest} = take_from_queue(acc, op.amount, [])

            {Enum.map(items, fn item ->
               %{
                 kind: :credit,
                 payment_operation_id: nil,
                 credit_lot_id: item.credit_lot_id,
                 amount: item.amount
               }
             end), rest}
        end
      end)

    Enum.filter(legacy ++ durable, &(&1.amount > 0))
  end

  defp applied_group_operations(group) do
    repo().all(from(r in Record, order_by: r.id))
    |> Enum.flat_map(fn record ->
      payload = Jason.decode!(record.payload)
      result = Jason.decode!(record.result)
      amount = payload["amount_cents"]

      cond do
        result["status"] != "applied" ->
          []

        payload["group_id"] != group.group_id ->
          []

        record.type == "record_cash_payment" and is_integer(amount) ->
          [%{type: :cash, operation_id: record.operation_id, amount: amount}]

        record.type == "apply_hotel_credit" and is_integer(amount) ->
          [%{type: :credit, operation_id: record.operation_id, amount: amount}]

        true ->
          []
      end
    end)
  end

  defp total(ops, kind),
    do: ops |> Enum.filter(&(&1.type == kind)) |> Enum.map(& &1.amount) |> Enum.sum()

  defp take_from_queue([entry | rest], need, acc) when need > 0 do
    take = min(entry.amount, need)

    if take == entry.amount do
      take_from_queue(rest, need - take, [entry | acc])
    else
      remainder = %{credit_lot_id: entry.credit_lot_id, amount: entry.amount - take}

      take_from_queue(
        [remainder | rest],
        need - take,
        [%{credit_lot_id: entry.credit_lot_id, amount: take} | acc]
      )
    end
  end

  defp take_from_queue(queue, _need, acc), do: {Enum.reverse(acc), queue}

  defp place_item(_repo, _group, _item, []), do: []

  defp place_item(repo, group, item, rooms) do
    {placed, rooms} = walk_rooms(repo, group, item, item.amount, rooms, [])
    if placed != item.amount, do: raise("legacy funding exceeds active deposit capacity")
    rooms
  end

  defp walk_rooms(_repo, _group, _item, 0, rooms, acc), do: {0, Enum.reverse(acc, rooms)}

  defp walk_rooms(_repo, _group, _item, need, [], _acc) do
    {need, []}
  end

  defp walk_rooms(repo, group, item, need, [room | rest], acc) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

    if capacity <= 0 do
      walk_rooms(repo, group, item, need, rest, [room | acc])
    else
      take = min(capacity, need)
      record_take!(repo, group, room, item, take)
      room = apply_take(room, item, take)

      {placed, rooms} = walk_rooms(repo, group, item, need - take, rest, [])
      {placed + take, Enum.reverse(acc, [room | rooms])}
    end
  end

  defp record_take!(repo, group, room, %{kind: :cash} = item, take) do
    repo.insert!(%RoomCashAllocation{
      group_id: group.id,
      room_id: room.id,
      payment_operation_id: item.payment_operation_id,
      amount_cents: take,
      disposition: "held"
    })
  end

  defp record_take!(repo, group, room, %{kind: :credit} = item, take) do
    # Select only the columns this migration owns: later releases may have
    # added schema fields whose database columns do not exist here yet.
    existing =
      repo.one(
        from(a in RoomCreditApplication,
          where: a.room_id == ^room.id and a.credit_lot_id == ^item.credit_lot_id,
          select: %{id: a.id, applied_cents: a.applied_cents}
        )
      )

    case existing do
      nil ->
        repo.insert!(%RoomCreditApplication{
          group_id: group.id,
          room_id: room.id,
          credit_lot_id: item.credit_lot_id,
          applied_cents: take
        })

      application ->
        repo.update_all(
          from(a in RoomCreditApplication, where: a.id == ^application.id),
          inc: [applied_cents: take]
        )
    end
  end

  defp apply_take(room, %{kind: :cash}, take),
    do: update_room_row!(room, cash_paid_cents: room.cash_paid_cents + take)

  defp apply_take(room, %{kind: :credit}, take),
    do: update_room_row!(room, credit_paid_cents: room.credit_paid_cents + take)

  defp update_room_row!(room, changes) do
    room
    |> Ecto.Changeset.change(changes)
    |> repo().update!()
  end

  # Cancelled groups settled their money before this release existed. Durable
  # payments get disposition rows so reconciliation keeps summing to the
  # recorded amount; classification follows the group's own settlement totals.
  defp record_settled_dispositions!(group, rooms) do
    initial_buckets = [
      refunded: group.refunded_cents,
      retained: group.retained_cents,
      converted: group.cash_converted_to_credit_cents
    ]

    lots = cancellation_lots(group)

    applied_group_operations(group)
    |> Enum.filter(&(&1.type == :cash))
    |> Enum.reduce({initial_buckets, lots}, fn op, {buckets, lots} ->
      {classifications, buckets} = drain_buckets(buckets, op.amount, [])
      {lots, _} = insert_settled_rows(group, rooms, op.operation_id, classifications, lots)
      {buckets, lots}
    end)
  end

  defp drain_buckets(buckets, 0, acc), do: {Enum.reverse(acc), buckets}

  defp drain_buckets([], _remaining, acc), do: {Enum.reverse(acc), []}

  defp drain_buckets([{disposition, available} | rest], remaining, acc) do
    take = min(max(0, available), remaining)

    if take > 0 do
      drain_buckets(rest, remaining - take, [{disposition, take} | acc])
    else
      drain_buckets(rest, remaining, acc)
    end
  end

  defp insert_settled_rows(_group, _rooms, _operation_id, [], lots), do: {lots, :done}

  defp insert_settled_rows(group, rooms, operation_id, [{disposition, take} | rest], lots) do
    disposition = Atom.to_string(disposition)

    {lot_id, lots} =
      if disposition == "converted" do
        case lots do
          [lot | more] -> {lot.id, more}
          [] -> {nil, []}
        end
      else
        {nil, lots}
      end

    repo().insert!(%RoomCashAllocation{
      group_id: group.id,
      room_id: first_room_id(rooms),
      payment_operation_id: operation_id,
      amount_cents: take,
      disposition: disposition,
      credit_lot_id: lot_id
    })

    insert_settled_rows(group, rooms, operation_id, rest, lots)
  end

  defp cancellation_lots(group) do
    cancel_operation_ids =
      repo().all(from(r in Record, order_by: r.id))
      |> Enum.filter(fn record ->
        record.type == "cancel_group" &&
          Jason.decode!(record.result)["status"] == "applied" &&
          Jason.decode!(record.payload)["group_id"] == group.group_id
      end)
      |> Enum.map(& &1.operation_id)

    repo().all(
      from(l in CreditLot,
        where: l.source_operation_id in ^cancel_operation_ids,
        order_by: [asc: fragment("rowid")]
      )
    )
  end

  defp first_room_id([room | _]), do: room.id
  defp first_room_id([]), do: nil

  defp sync_group_columns!(group_id, rooms) do
    active = Enum.filter(rooms, &(&1.status == "active"))

    lodging_total = Enum.sum(Enum.map(active, & &1.lodging_cents))
    due_total = Enum.sum(Enum.map(active, & &1.deposit_due_cents))
    cash_total = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit_total = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    repo().update_all(
      from(g in Group, where: g.id == ^group_id),
      set: [
        lodging_total_cents: lodging_total,
        deposit_due_cents: due_total,
        cash_paid_cents: cash_total,
        credit_paid_cents: credit_total,
        deposit_paid_cents: cash_total + credit_total
      ]
    )
  end

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging
end
