defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payment_accountings) do
      add :has_transferred, :boolean, null: false, default: false
    end

    create table(:cash_settlements) do
      add :payment_operation_id, :string, null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_settlements, [:payment_operation_id])
    create index(:cash_settlements, [:group_id])

    # Before transfers existed, every settlement necessarily occurred on the payment's original
    # group. Preserve that location so future chargebacks can revise the right groups.
    execute("""
    INSERT INTO cash_settlements
      (payment_operation_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT payment_operation_id, original_group_id, 'refunded', refunded_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accountings WHERE refunded_cents > 0
    """)

    execute("""
    INSERT INTO cash_settlements
      (payment_operation_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT payment_operation_id, original_group_id, 'retained', retained_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accountings WHERE retained_cents > 0
    """)

    execute("""
    INSERT INTO cash_settlements
      (payment_operation_id, group_id, kind, amount_cents, inserted_at, updated_at)
    SELECT payment_operation_id, original_group_id, 'converted', converted_to_credit_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_accountings WHERE converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:cash_settlements)

    alter table(:payment_accountings) do
      remove :has_transferred
    end
  end
end
