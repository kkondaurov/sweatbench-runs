defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])
    flush()

    # The previous tables had independent IDs. Recover their shared funding
    # order from retained operation commit order, never partner dates. Legacy
    # funding precedes recorded funding: cash, then credit in consumption order.
    # Room position orders portions split by the room-accounting migration,
    # whose credit IDs need not themselves follow room fill order.
    allocations =
      repo().query!("""
      SELECT funding.kind, funding.id
      FROM (
        SELECT 'cash' AS kind, id, group_id, room_id, payment_operation_id AS operation_id,
          'record_cash_payment' AS operation_type, 0 AS lot_order
        FROM cash_allocations
        UNION ALL
        SELECT 'credit', id, group_id, room_id, operation_id, 'apply_hotel_credit',
          MIN(id) OVER (PARTITION BY group_id, operation_id, credit_lot_id)
        FROM credit_allocations
      ) AS funding
      LEFT JOIN operation_records AS record
        ON record.operation_id = funding.operation_id
        AND record.operation_type = funding.operation_type
        AND json_extract(record.result, '$.status') = 'applied'
      LEFT JOIN rooms AS room ON room.id = funding.room_id
      ORDER BY COALESCE(record.id, 0), funding.group_id, funding.kind,
        funding.lot_order, room.position, funding.id
      """).rows

    allocations
    |> Enum.with_index(1)
    |> Enum.each(fn {[kind, id], order} ->
      table = if kind == "cash", do: "cash_allocations", else: "credit_allocations"
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [order, id])
    end)
  end

  def down do
    # Prior code cannot preserve transfer participation or order across kinds.
    if repo().query!("""
       SELECT id FROM operation_records
       WHERE operation_type = 'transfer_deposit'
         AND json_extract(result, '$.status') = 'applied' LIMIT 1
       """).rows != [] do
      raise Ecto.MigrationError, message: "cannot downgrade after deposit transfers"
    end

    drop index(:cash_allocations, [:allocation_order])
    drop index(:credit_allocations, [:allocation_order])

    alter table(:cash_allocations) do
      remove :allocation_order
      remove :transferred
    end

    alter table(:credit_allocations), do: remove(:allocation_order)
  end
end
