defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer
    end

    execute("""
    WITH allocation_rows AS (
      SELECT id, group_id, 0 AS kind, payment_operation_id AS operation_id
      FROM cash_allocations
      UNION ALL
      SELECT id, group_id, 1 AS kind, funding_operation_id AS operation_id
      FROM credit_allocations
    ),
    numbered AS (
      SELECT id, group_id, kind,
        row_number() OVER (
          ORDER BY group_id,
            CASE WHEN operation_id IS NULL THEN 0 ELSE 1 END,
            CASE WHEN operation_id IS NULL THEN kind ELSE 0 END,
            COALESCE((SELECT id FROM operations WHERE operations.operation_id = allocation_rows.operation_id), 0),
            kind, id
        ) AS allocation_order
      FROM allocation_rows
    )
    UPDATE cash_allocations
    SET allocation_order = (
      SELECT allocation_order
      FROM numbered
      WHERE numbered.id = cash_allocations.id
        AND numbered.group_id = cash_allocations.group_id
        AND numbered.kind = 0
    )
    """)

    execute("""
    WITH allocation_rows AS (
      SELECT id, group_id, 0 AS kind, payment_operation_id AS operation_id
      FROM cash_allocations
      UNION ALL
      SELECT id, group_id, 1 AS kind, funding_operation_id AS operation_id
      FROM credit_allocations
    ),
    numbered AS (
      SELECT id, group_id, kind,
        row_number() OVER (
          ORDER BY group_id,
            CASE WHEN operation_id IS NULL THEN 0 ELSE 1 END,
            CASE WHEN operation_id IS NULL THEN kind ELSE 0 END,
            COALESCE((SELECT id FROM operations WHERE operations.operation_id = allocation_rows.operation_id), 0),
            kind, id
        ) AS allocation_order
      FROM allocation_rows
    )
    UPDATE credit_allocations
    SET allocation_order = (
      SELECT allocation_order
      FROM numbered
      WHERE numbered.id = credit_allocations.id
        AND numbered.group_id = credit_allocations.group_id
        AND numbered.kind = 1
    )
    """)

    alter table(:payment_accountings) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create table(:payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_dispositions, [:payment_operation_id, :group_id])
    create index(:payment_dispositions, [:payment_operation_id])
    create index(:payment_dispositions, [:group_id])
  end

  def down do
    drop table(:payment_dispositions)

    alter table(:payment_accountings) do
      remove :transfer_participated
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end
end
