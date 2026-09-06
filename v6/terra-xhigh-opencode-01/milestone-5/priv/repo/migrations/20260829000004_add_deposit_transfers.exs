defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_room_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:cash_payment_sources) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create index(:cash_room_allocations, [:allocation_order])
    create index(:credit_allocations, [:allocation_order])

    flush()

    # Earlier releases stored cash and credit allocation identities separately. Give those rows a
    # stable shared order before new transfers begin creating a single cross-kind sequence.
    execute("UPDATE cash_room_allocations SET allocation_order = id * 2")
    execute("UPDATE credit_allocations SET allocation_order = id * 2 + 1")
  end

  def down do
    drop index(:credit_allocations, [:allocation_order])
    drop index(:cash_room_allocations, [:allocation_order])

    alter table(:cash_payment_sources) do
      remove :participated_in_transfer
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_room_allocations) do
      remove :allocation_order
    end
  end
end
