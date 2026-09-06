defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def change do
    alter table(:cash_allocations) do
      add :allocation_sequence, :integer
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_sequence, :integer
    end

    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create index(:cash_allocations, [:allocation_sequence])
    create index(:hotel_credit_allocations, [:allocation_sequence])
  end
end
