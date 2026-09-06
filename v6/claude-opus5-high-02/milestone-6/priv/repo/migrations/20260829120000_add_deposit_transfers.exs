defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  alias GroupStay.Reservations.AllocationOrder

  def up do
    # Cash and credit fund the same room deposits, and a transfer draws from both in one order, so
    # the two tables share the sequence that records it.
    alter table(:cash_allocations) do
      add :allocation_seq, :integer, null: false, default: 0
      add :transferred, :boolean, null: false, default: false
    end

    alter table(:credit_applications) do
      add :allocation_seq, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:allocation_seq])
    create index(:credit_applications, [:allocation_seq])

    flush()

    AllocationOrder.backfill()
  end

  def down do
    drop index(:cash_allocations, [:allocation_seq])
    drop index(:credit_applications, [:allocation_seq])

    alter table(:cash_allocations) do
      remove :allocation_seq
      remove :transferred
    end

    alter table(:credit_applications) do
      remove :allocation_seq
    end
  end
end
