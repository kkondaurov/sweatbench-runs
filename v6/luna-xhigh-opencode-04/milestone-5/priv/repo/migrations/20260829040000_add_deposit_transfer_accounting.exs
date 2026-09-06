defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  alias GroupStay.Operations

  @disable_ddl_transaction true

  def up do
    create table(:allocation_orders) do
    end

    alter table(:cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:payment_accountings) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    execute "INSERT INTO allocation_orders (id) VALUES (0)"

    create index(:cash_allocations, [:group_id, :allocation_order])
    create index(:cash_allocations, [:payment_operation_id, :allocation_order])
    create index(:credit_allocations, [:group_id, :allocation_order])

    Operations.backfill_allocation_orders()
    Operations.backfill_all_groups()
  end

  def down do
    drop index(:credit_allocations, [:group_id, :allocation_order])
    drop index(:cash_allocations, [:payment_operation_id, :allocation_order])
    drop index(:cash_allocations, [:group_id, :allocation_order])

    alter table(:payment_accountings) do
      remove :transfer_participated
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end

    drop table(:allocation_orders)
  end
end
