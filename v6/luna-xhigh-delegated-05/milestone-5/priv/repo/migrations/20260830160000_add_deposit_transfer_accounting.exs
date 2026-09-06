defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def up do
    alter table(:cash_payment_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:cash_payment_states) do
      add :transferred, :boolean, null: false, default: false
    end

    flush()
    GroupStay.Operations.backfill_allocation_orders!()
  end

  def down do
    alter table(:cash_payment_states) do
      remove :transferred
    end

    alter table(:hotel_credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_payment_allocations) do
      remove :allocation_order
    end
  end
end
