defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])

    create table(:cash_payment_transfers) do
      add :payment_operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_transfers, [:payment_operation_id])

    # Earlier allocation rows did not have one ordering shared by cash and credit. Their
    # original exact interleaving was not persisted, so give them a deterministic historical
    # order before all newly-created allocations receive a monotonic shared order.
    execute("""
    WITH ordered AS (
      SELECT kind, id,
             ROW_NUMBER() OVER (ORDER BY inserted_at ASC, kind ASC, id ASC) - 1 AS allocation_order
      FROM (
        SELECT 'cash' AS kind, id, inserted_at FROM cash_allocations
        UNION ALL
        SELECT 'credit' AS kind, id, inserted_at FROM credit_allocations
      )
    )
    UPDATE cash_allocations
    SET allocation_order = (
      SELECT allocation_order FROM ordered
      WHERE ordered.kind = 'cash' AND ordered.id = cash_allocations.id
    )
    """)

    execute("""
    WITH ordered AS (
      SELECT kind, id,
             ROW_NUMBER() OVER (ORDER BY inserted_at ASC, kind ASC, id ASC) - 1 AS allocation_order
      FROM (
        SELECT 'cash' AS kind, id, inserted_at FROM cash_allocations
        UNION ALL
        SELECT 'credit' AS kind, id, inserted_at FROM credit_allocations
      )
    )
    UPDATE credit_allocations
    SET allocation_order = (
      SELECT allocation_order FROM ordered
      WHERE ordered.kind = 'credit' AND ordered.id = credit_allocations.id
    )
    """)
  end

  def down do
    drop table(:cash_payment_transfers)
    drop index(:credit_allocations, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end
end
