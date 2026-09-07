defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create table(:cash_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_record_id, references(:groups, on_delete: :restrict), null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_settlements, [:payment_operation_id, :group_record_id])
    create index(:cash_settlements, [:group_record_id])

    execute("""
    INSERT INTO cash_settlements
      (payment_operation_id, group_record_id, refunded_cents, retained_cents,
       converted_to_credit_cents, inserted_at, updated_at)
    SELECT operation_id, group_record_id, refunded_cents, retained_cents,
           converted_to_credit_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cash_payments
     WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:cash_settlements)

    alter table(:cash_payments) do
      remove :transfer_participated
    end
  end
end
