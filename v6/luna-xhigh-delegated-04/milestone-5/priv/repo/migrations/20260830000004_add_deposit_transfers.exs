defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :transferred, :boolean, null: false, default: false
      add :allocation_sequence, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_sequence, :integer, null: false, default: 0
    end

    flush()
    GroupStay.backfill_room_accounting!()
    GroupStay.backfill_allocation_order!()
  end

  def down do
    alter table(:hotel_credit_allocations) do
      remove :allocation_sequence
    end

    alter table(:cash_allocations) do
      remove :transferred
      remove :allocation_sequence
    end
  end
end
