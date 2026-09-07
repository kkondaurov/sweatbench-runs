defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    # Older release-04 databases do not have these columns. Fresh databases do,
    # because the procedural release-04 backfill runs through current schemas.
    execute(fn -> GroupStay.Reservations.AllocationOrder.prepare_upgrade(repo()) end)

    flush()
    execute(fn -> GroupStay.Reservations.AllocationOrder.backfill() end)

    create_if_not_exists unique_index(:cash_allocations, [:allocation_order])
    create_if_not_exists unique_index(:credit_allocations, [:allocation_order])
  end

  def down do
    drop_if_exists index(:credit_allocations, [:allocation_order])
    drop_if_exists index(:cash_allocations, [:allocation_order])

    alter table(:cash_fundings) do
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
