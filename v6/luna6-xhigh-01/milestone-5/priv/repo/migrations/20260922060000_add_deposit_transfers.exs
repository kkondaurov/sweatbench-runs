defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payment_allocations) do
      add :transferred, :boolean, null: false, default: false
      add :allocation_operation_id, :string
      add :allocation_position, :integer
    end

    alter table(:hotel_credit_allocations) do
      add :allocation_operation_id, :string
      add :allocation_position, :integer
    end

    execute """
    UPDATE cash_payment_allocations
    SET allocation_operation_id = payment_operation_id
    WHERE payment_operation_id IS NOT NULL
    """

    execute """
    UPDATE hotel_credit_allocations
    SET allocation_operation_id = funding_operation_id
    WHERE funding_operation_id IS NOT NULL
    """

    create index(:cash_payment_allocations, [:allocation_operation_id])
    create index(:hotel_credit_allocations, [:allocation_operation_id])
  end

  def down do
    drop index(:hotel_credit_allocations, [:allocation_operation_id])
    drop index(:cash_payment_allocations, [:allocation_operation_id])

    alter table(:hotel_credit_allocations) do
      remove :allocation_position
      remove :allocation_operation_id
    end

    alter table(:cash_payment_allocations) do
      remove :allocation_position
      remove :allocation_operation_id
      remove :transferred
    end
  end
end
