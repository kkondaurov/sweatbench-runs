defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create index(:cash_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])

    create table(:cash_payment_group_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :cash_payment_id,
          references(:cash_payments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_group_dispositions, [
             :cash_payment_id,
             :group_record_id
           ])

    create index(:cash_payment_group_dispositions, [:group_record_id])

    flush()
    GroupStay.DepositTransferBackfill.run(repo())
  end

  def down do
    drop table(:cash_payment_group_dispositions)
    drop index(:credit_allocations, [:allocation_order])
    drop index(:cash_allocations, [:allocation_order])

    alter table(:cash_payments) do
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
