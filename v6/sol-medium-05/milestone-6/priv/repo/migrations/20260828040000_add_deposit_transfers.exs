defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer
    end

    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:cash_allocations, [:group_id, :allocation_order])
    create index(:credit_allocations, [:allocation_order])
    create index(:credit_allocations, [:group_id, :allocation_order])

    create table(:cash_payment_dispositions) do
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all), null: false
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_dispositions, [:cash_payment_id, :group_id])
    create index(:cash_payment_dispositions, [:group_id])

    # Before transfers existed every settled payment was necessarily settled in
    # its original group, so the aggregate payment dispositions are sufficient
    # to seed the new per-group history.
    execute("""
    INSERT INTO cash_payment_dispositions
      (cash_payment_id, group_id, refunded_cents, retained_cents, converted_cents,
       inserted_at, updated_at)
    SELECT id, group_id, refunded_cents, retained_cents, converted_cents,
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_cents > 0
    """)

    # Preserve the best available chronology for allocations created by older
    # releases. New allocations use one sequence shared by both funding kinds.
    execute("""
    UPDATE cash_allocations
    SET allocation_order = id * 2 - 1
    """)

    execute("""
    UPDATE credit_allocations
    SET allocation_order = id * 2
    """)
  end

  def down do
    drop table(:cash_payment_dispositions)
    drop_if_exists index(:credit_allocations, [:group_id, :allocation_order])
    drop_if_exists index(:credit_allocations, [:allocation_order])
    drop_if_exists index(:cash_allocations, [:group_id, :allocation_order])
    drop_if_exists index(:cash_allocations, [:allocation_order])

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end
end
