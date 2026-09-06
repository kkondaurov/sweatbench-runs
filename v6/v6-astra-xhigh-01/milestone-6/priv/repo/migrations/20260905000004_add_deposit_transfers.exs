defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payments) do
      add :transferred, :boolean, null: false, default: false
    end

    # Settled cash no longer necessarily belongs to the payment's original group.
    # Keep its location so a chargeback can correct each group's finance totals.
    create table(:payment_settlements) do
      add :payment_operation_id,
          references(:payments, column: :payment_operation_id, type: :string), null: false

      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :refunded_cents, :bigint, null: false, default: 0
      add :retained_cents, :bigint, null: false, default: 0
      add :converted_to_credit_cents, :bigint, null: false, default: 0
    end

    create unique_index(:payment_settlements, [:payment_operation_id, :group_id])
    create index(:funding_allocations, [:group_id, :id])

    execute """
    INSERT INTO payment_settlements
      (payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents)
    SELECT payment_operation_id, original_group_id, refunded_cents, retained_cents, converted_to_credit_cents
    FROM payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """
  end

  def down do
    drop index(:funding_allocations, [:group_id, :id])
    drop table(:payment_settlements)
    execute "ALTER TABLE payments DROP COLUMN transferred"
  end
end
