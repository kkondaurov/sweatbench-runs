defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:funding_allocation_orders) do
    end

    alter table(:cash_allocations) do
      add :allocation_order, references(:funding_allocation_orders)
    end

    alter table(:credit_allocations) do
      add :allocation_order, references(:funding_allocation_orders)
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create table(:cash_payment_dispositions) do
      add :payment_operation_id,
          references(:cash_payments, column: :operation_id, type: :text, on_delete: :restrict),
          null: false

      add :group_id,
          references(:groups, column: :group_id, type: :text, on_delete: :restrict),
          null: false

      add :disposition, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_allocations, [:group_id, :allocation_order])
    create index(:cash_allocations, [:payment_operation_id, :allocation_order])
    create index(:credit_allocations, [:group_id, :allocation_order])
    create index(:cash_payment_dispositions, [:payment_operation_id])
    create index(:cash_payment_dispositions, [:group_id])

    flush()
    GroupStay.Operations.backfill_deposit_transfers!()
  end

  def down do
    drop table(:cash_payment_dispositions)

    alter table(:cash_payments) do
      remove :transfer_participated
    end

    drop_if_exists index(:credit_allocations, [:group_id, :allocation_order])

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    drop_if_exists index(:cash_allocations, [:payment_operation_id, :allocation_order])
    drop_if_exists index(:cash_allocations, [:group_id, :allocation_order])

    alter table(:cash_allocations) do
      remove :allocation_order
    end

    drop table(:funding_allocation_orders)
  end
end
