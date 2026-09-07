defmodule GroupStay.Repo.Migrations.AddDepositTransferTracking do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations), do: add(:allocation_order, :integer)
    alter table(:credit_allocations), do: add(:allocation_order, :integer)

    alter table(:payment_dispositions) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    flush()

    # The previous release created each funding block in its allocation order. Merge the two
    # allocation tables into one deterministic sequence so upgraded databases can compare cash
    # and credit rows. Future rows receive orders from this same global sequence.
    execute("""
    CREATE TEMPORARY TABLE allocation_order_upgrade AS
      SELECT kind, allocation_id,
             ROW_NUMBER() OVER (
               ORDER BY group_id, operation_order, kind, room_id, allocation_id
             ) allocation_order
        FROM (
          SELECT 'cash' kind, a.id allocation_id, a.group_id, a.room_id,
                 COALESCE(r.id, 0) operation_order
            FROM cash_allocations a
            LEFT JOIN operation_records r ON r.operation_id = a.payment_operation_id
          UNION ALL
          SELECT 'credit' kind, a.id allocation_id, a.group_id, a.room_id,
                 COALESCE(r.id, 0) operation_order
            FROM credit_allocations a
            LEFT JOIN operation_records r ON r.operation_id = a.operation_id
        )
    """)

    execute("""
    UPDATE cash_allocations
       SET allocation_order = (
         SELECT allocation_order FROM allocation_order_upgrade
          WHERE kind = 'cash' AND allocation_id = cash_allocations.id
       )
    """)

    execute("""
    UPDATE credit_allocations
       SET allocation_order = (
         SELECT allocation_order FROM allocation_order_upgrade
          WHERE kind = 'credit' AND allocation_id = credit_allocations.id
       )
    """)

    execute("DROP TABLE allocation_order_upgrade")

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])
  end

  def down do
    drop index(:credit_allocations, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:payment_dispositions), do: remove(:participated_in_transfer)
    alter table(:credit_allocations), do: remove(:allocation_order)
    alter table(:cash_allocations), do: remove(:allocation_order)
  end
end
