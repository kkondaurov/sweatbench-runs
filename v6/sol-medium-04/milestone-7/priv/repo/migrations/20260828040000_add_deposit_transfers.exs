defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_applications) do
      add :allocation_order, :integer
    end

    alter table(:payment_accounts) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:cash_dispositions) do
      add :payment_account_id, references(:payment_accounts, on_delete: :restrict), null: false
      add :group_id, references(:groups, type: :string, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_dispositions, [:payment_account_id])
    create index(:cash_dispositions, [:group_id])

    execute """
    UPDATE cash_allocations
    SET allocation_order = CASE
      WHEN payment_account_id IS NULL THEN id
      ELSE 1000000000 +
        COALESCE((SELECT operation_record_id FROM payment_accounts
                  WHERE payment_accounts.id = cash_allocations.payment_account_id), 0) * 1000000 +
        COALESCE((SELECT position FROM rooms WHERE rooms.id = cash_allocations.room_id), 0) * 10000 +
        id
    END
    """

    execute """
    UPDATE credit_applications
    SET allocation_order = CASE
      WHEN funding_operation_id IS NULL THEN 500000000 + id
      ELSE 1000000000 +
        COALESCE((SELECT id FROM operation_records
                  WHERE operation_records.operation_id = credit_applications.funding_operation_id), 0) * 1000000 +
        COALESCE((SELECT position FROM rooms WHERE rooms.id = credit_applications.room_id), 0) * 10000 +
        id
    END
    """

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_applications, [:allocation_order])

    execute """
    INSERT INTO cash_dispositions
      (payment_account_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT id, group_id, 'refunded', refunded_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accounts
    WHERE refunded_cents > 0
    """

    execute """
    INSERT INTO cash_dispositions
      (payment_account_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT id, group_id, 'retained', retained_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accounts
    WHERE retained_cents > 0
    """

    execute """
    INSERT INTO cash_dispositions
      (payment_account_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT id, group_id, 'converted', converted_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accounts
    WHERE converted_cents > 0
    """
  end

  def down do
    drop table(:cash_dispositions)
    drop index(:credit_applications, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:payment_accounts) do
      remove :participated_in_transfer
    end

    alter table(:credit_applications) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end
end
