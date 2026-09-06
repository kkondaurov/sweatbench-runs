defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer
    end

    alter table(:cash_payments) do
      add :transferred, :boolean, null: false, default: false
    end

    execute """
    UPDATE cash_allocations
    SET allocation_order = id
    WHERE allocation_order IS NULL
    """

    execute """
    UPDATE credit_allocations
    SET allocation_order = id + COALESCE((SELECT MAX(id) FROM cash_allocations), 0)
    WHERE allocation_order IS NULL
    """

    create table(:cash_payment_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_settlements, [:payment_operation_id, :group_id])
    create index(:cash_payment_settlements, [:group_id])
  end

  def down do
    drop table(:cash_payment_settlements)

    alter table(:cash_payments) do
      remove :transferred
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end
end
