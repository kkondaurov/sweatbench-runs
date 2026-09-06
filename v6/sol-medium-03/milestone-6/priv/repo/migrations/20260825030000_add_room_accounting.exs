defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    create table(:cash_payments, primary_key: false) do
      add :operation_id, :string, primary_key: true

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :restrict),
          null: false

      add :recorded_cents, :integer, null: false
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:cash_payments, [:group_id])

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:cash_dispositions) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      timestamps(type: :utc_datetime)
    end

    create index(:cash_dispositions, [:group_id])
    create index(:cash_dispositions, [:payment_operation_id])
    create index(:cash_dispositions, [:kind])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    backfill_room_amounts()
    backfill_accounting()

    execute("UPDATE rooms SET lodging_total_cents = 0 WHERE lodging_total_cents IS NULL")
    execute("UPDATE rooms SET deposit_due_cents = 0 WHERE deposit_due_cents IS NULL")
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_dispositions)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill_room_amounts do
    sql!("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents *
      (SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
       FROM groups WHERE groups.group_id = rooms.group_id)
    """)

    sql!("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
        THEN lodging_total_cents
      ELSE CAST((lodging_total_cents * 20 + 50) / 100 AS INTEGER)
    END
    """)
  end

  defp backfill_accounting do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    operations = durable_funding_operations()

    Enum.each(operations.cash, fn operation ->
      sql!(
        "INSERT INTO cash_payments (operation_id, group_id, recorded_cents, reduced_cents, charged_back_cents, inserted_at, updated_at) VALUES (?, ?, ?, 0, 0, ?, ?)",
        [operation.operation_id, operation.group_id, operation.amount, timestamp, timestamp]
      )
    end)

    rows =
      sql!(
        "SELECT group_id, status, cash_paid_cents, credit_paid_cents, refunded_cents, retained_cents, cash_converted_to_credit_cents FROM groups ORDER BY group_id"
      ).rows

    Enum.each(rows, fn [group_id, status, cash, credit, refunded, retained, converted] ->
      cash_ops = Enum.filter(operations.cash, &(&1.group_id == group_id))
      credit_ops = Enum.filter(operations.credit, &(&1.group_id == group_id))
      cash_sources = funding_sources(cash, cash_ops)

      if status == "active" do
        rebuild_active_allocations(group_id, cash, credit, cash_ops, credit_ops, timestamp)
      else
        kind = historical_kind(refunded, retained, converted)
        lot_id = if kind == "converted", do: converted_lot_id(group_id, operations.cancellations)
        record_historical_dispositions(group_id, cash_sources, kind, lot_id, timestamp)

        if kind == "converted" and lot_id do
          record_entitlements(lot_id, cash_sources, timestamp)
        end
      end
    end)
  end

  defp durable_funding_operations do
    rows =
      sql!("SELECT id, operation_id, operation_type, result FROM partner_operations ORDER BY id").rows

    parsed =
      Enum.map(rows, fn [id, operation_id, type, result] ->
        result = decode_json(result)

        %{
          id: id,
          operation_id: operation_id,
          type: type,
          status: result["status"],
          group_id: result["group_id"],
          amount: result["amount_cents"] || 0,
          credit_issued: result["credit_issued_cents"] || 0
        }
      end)

    %{
      cash: Enum.filter(parsed, &(&1.type == "record_cash_payment" and &1.status == "applied")),
      credit: Enum.filter(parsed, &(&1.type == "apply_hotel_credit" and &1.status == "applied")),
      cancellations:
        Enum.filter(parsed, &(&1.type in ["cancel_group"] and &1.status == "applied"))
    }
  end

  defp funding_sources(total, operations) do
    durable_total = Enum.sum(Enum.map(operations, & &1.amount))
    legacy = max(total - durable_total, 0)
    legacy_source = if legacy > 0, do: [%{operation_id: nil, amount: legacy}], else: []
    legacy_source ++ Enum.map(operations, &%{operation_id: &1.operation_id, amount: &1.amount})
  end

  defp room_capacities(group_id) do
    sql!("SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? ORDER BY position", [
      group_id
    ]).rows
    |> Enum.map(fn [id, due] -> %{id: id, remaining: due} end)
  end

  defp rebuild_active_allocations(group_id, cash, credit, cash_ops, credit_ops, timestamp) do
    old =
      sql!(
        "SELECT id, credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
        [group_id]
      ).rows

    sql!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

    lot_stream = Enum.map(old, fn [_id, lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)
    legacy_cash = max(cash - Enum.sum(Enum.map(cash_ops, & &1.amount)), 0)
    legacy_credit = max(credit - Enum.sum(Enum.map(credit_ops, & &1.amount)), 0)

    legacy =
      if(legacy_cash > 0, do: [%{kind: :cash, operation_id: nil, amount: legacy_cash}], else: []) ++
        if legacy_credit > 0,
          do: [%{kind: :credit, operation_id: nil, amount: legacy_credit}],
          else: []

    durable =
      (Enum.map(cash_ops, &Map.put(&1, :kind, :cash)) ++
         Enum.map(credit_ops, &Map.put(&1, :kind, :credit)))
      |> Enum.sort_by(& &1.id)

    Enum.reduce(legacy ++ durable, {room_capacities(group_id), lot_stream}, fn event,
                                                                               {rooms, stream} ->
      case event.kind do
        :cash -> {allocate_cash_event(group_id, rooms, event, timestamp), stream}
        :credit -> allocate_credit_event(group_id, rooms, stream, event, timestamp)
      end
    end)
  end

  defp allocate_cash_event(group_id, rooms, event, timestamp) do
    {rooms, _} =
      allocate_over_rooms(rooms, event.amount, fn room_id, amount ->
        sql!(
          "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
          [group_id, room_id, event.operation_id, amount, timestamp, timestamp]
        )

        sql!("UPDATE rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?", [
          amount,
          room_id
        ])
      end)

    rooms
  end

  defp allocate_credit_event(group_id, rooms, stream, event, timestamp) do
    {chunks, stream} = take_lot_chunks(stream, event.amount, [])

    rooms =
      Enum.reduce(chunks, rooms, fn %{lot_id: lot_id, amount: amount}, state ->
        {state, _} =
          allocate_over_rooms(state, amount, fn room_id, used ->
            sql!(
              "INSERT INTO credit_allocations (group_id, credit_lot_id, room_id, funding_operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
              [group_id, lot_id, room_id, event.operation_id, used, timestamp, timestamp]
            )

            sql!("UPDATE rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?", [
              used,
              room_id
            ])
          end)

        state
      end)

    {rooms, stream}
  end

  defp allocate_over_rooms(rooms, amount, callback) do
    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        used = min(room.remaining, left)
        if used > 0, do: callback.(room.id, used)
        {%{room | remaining: room.remaining - used}, left - used}
      end)

    {rooms, amount - remaining}
  end

  defp take_lot_chunks(stream, 0, acc), do: {Enum.reverse(acc), stream}
  defp take_lot_chunks([], _amount, acc), do: {Enum.reverse(acc), []}

  defp take_lot_chunks([lot | rest], amount, acc) do
    used = min(lot.amount, amount)
    remaining_lot = lot.amount - used
    rest = if remaining_lot > 0, do: [%{lot | amount: remaining_lot} | rest], else: rest
    take_lot_chunks(rest, amount - used, [%{lot_id: lot.lot_id, amount: used} | acc])
  end

  defp historical_kind(refunded, _retained, _converted) when refunded > 0, do: "refunded"
  defp historical_kind(_refunded, retained, _converted) when retained > 0, do: "retained"
  defp historical_kind(_refunded, _retained, converted) when converted > 0, do: "converted"
  defp historical_kind(_, _, _), do: nil

  defp record_historical_dispositions(_group_id, _sources, nil, _lot_id, _timestamp), do: :ok

  defp record_historical_dispositions(group_id, sources, kind, lot_id, timestamp) do
    Enum.each(sources, fn source ->
      sql!(
        "INSERT INTO cash_dispositions (group_id, payment_operation_id, kind, amount_cents, credit_lot_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [group_id, source.operation_id, kind, source.amount, lot_id, timestamp, timestamp]
      )
    end)
  end

  defp converted_lot_id(group_id, cancellations) do
    source_ids =
      cancellations
      |> Enum.filter(&(&1.group_id == group_id and &1.credit_issued > 0))
      |> Enum.map(& &1.operation_id)

    case source_ids do
      [] ->
        nil

      ids ->
        sql!(
          "SELECT id FROM credit_lots WHERE source_operation_id IN (#{Enum.map_join(ids, ",", fn _ -> "?" end)}) ORDER BY id DESC LIMIT 1",
          ids
        ).rows
        |> List.first()
        |> then(fn row -> row && hd(row) end)
    end
  end

  defp record_entitlements(lot_id, sources, timestamp) do
    Enum.reduce(sources, 0, fn source, preceding ->
      running = preceding + source.amount
      entitlement = bonus_value(running) - bonus_value(preceding)

      sql!(
        "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, principal_cents, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        [lot_id, source.operation_id, source.amount, entitlement, timestamp, timestamp]
      )

      running
    end)
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(repo(), statement, params)
end
