defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:funding_allocation_sequences) do
      timestamps(type: :utc_datetime)
    end

    alter table(:room_cash_allocations) do
      add :allocation_sequence_id, references(:funding_allocation_sequences, on_delete: :restrict)
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_sequence_id, references(:funding_allocation_sequences, on_delete: :restrict)
    end

    create unique_index(:room_cash_allocations, [:allocation_sequence_id])
    create unique_index(:hotel_credit_allocations, [:allocation_sequence_id])

    alter table(:cash_payment_accountings) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:cash_payment_settlements) do
      add :payment_accounting_id,
          references(:cash_payment_accountings, on_delete: :restrict),
          null: false

      add :group_id,
          references(:group_reservations,
            column: :group_id,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_settlements, [:payment_accounting_id, :group_id])
    create index(:cash_payment_settlements, [:group_id])

    backfill_allocation_sequence()
    backfill_payment_settlements()
  end

  def down do
    drop table(:cash_payment_settlements)

    alter table(:cash_payment_accountings) do
      remove :participated_in_transfer
    end

    drop index(:hotel_credit_allocations, [:allocation_sequence_id])

    alter table(:hotel_credit_allocations) do
      remove :allocation_sequence_id
    end

    drop index(:room_cash_allocations, [:allocation_sequence_id])

    alter table(:room_cash_allocations) do
      remove :allocation_sequence_id
    end

    drop table(:funding_allocation_sequences)
  end

  defp backfill_allocation_sequence do
    # Older rows have no shared sequence. Their timestamps and per-table identifiers provide a
    # stable upgrade order; all allocations created after this migration use the shared sequence
    # directly and therefore have an exact cross-kind order.
    execute("""
    CREATE TEMP TABLE funding_allocation_migration_order (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      allocation_id INTEGER NOT NULL
    )
    """)

    execute("""
    INSERT INTO funding_allocation_migration_order (kind, allocation_id)
    SELECT kind, allocation_id
      FROM (
        SELECT 'cash' AS kind, allocation.id AS allocation_id,
               CASE WHEN allocation.payment_accounting_id IS NULL THEN 0 ELSE 1 END AS seniority,
               COALESCE(operation.inserted_at, allocation.inserted_at) AS allocated_at,
               COALESCE(operation.id, allocation.id) AS source_order
          FROM room_cash_allocations allocation
          LEFT JOIN cash_payment_accountings payment
            ON payment.id = allocation.payment_accounting_id
          LEFT JOIN partner_operation_records operation
            ON operation.id = payment.operation_record_id
        UNION ALL
        SELECT 'credit' AS kind, id AS allocation_id, 1 AS seniority,
               inserted_at AS allocated_at, id AS source_order
          FROM hotel_credit_allocations
      )
     ORDER BY seniority, allocated_at, source_order, kind, allocation_id
    """)

    execute("""
    INSERT INTO funding_allocation_sequences (id, inserted_at, updated_at)
    SELECT sequence, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM funding_allocation_migration_order
    """)

    execute("""
    UPDATE room_cash_allocations
       SET allocation_sequence_id = (
         SELECT sequence FROM funding_allocation_migration_order
          WHERE kind = 'cash' AND allocation_id = room_cash_allocations.id
       )
    """)

    execute("""
    UPDATE hotel_credit_allocations
       SET allocation_sequence_id = (
         SELECT sequence FROM funding_allocation_migration_order
          WHERE kind = 'credit' AND allocation_id = hotel_credit_allocations.id
       )
    """)

    execute("DROP TABLE funding_allocation_migration_order")
  end

  defp backfill_payment_settlements do
    # Before transfers, every payment disposition necessarily settled on its original group.
    execute("""
    INSERT INTO cash_payment_settlements
      (payment_accounting_id, group_id, refunded_cents, retained_cents,
       converted_to_credit_cents, inserted_at, updated_at)
    SELECT id, group_id, refunded_cents, retained_cents, converted_to_credit_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cash_payment_accountings
     WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
  end
end
