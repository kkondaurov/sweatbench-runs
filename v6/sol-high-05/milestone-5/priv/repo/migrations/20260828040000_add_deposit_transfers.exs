defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:payment_dispositions) do
      add :transfer_participated, :boolean, null: false, default: false
    end

    create table(:payment_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:payment_settlements, [:payment_operation_id])
    create index(:payment_settlements, [:group_id])

    execute("""
    INSERT INTO payment_settlements (
      payment_operation_id, group_id, disposition, amount_cents, inserted_at
    )
    SELECT payment_operation_id, original_group_id, 'refunded', refunded_cents, CURRENT_TIMESTAMP
    FROM payment_dispositions
    WHERE refunded_cents > 0
    """)

    execute("""
    INSERT INTO payment_settlements (
      payment_operation_id, group_id, disposition, amount_cents, inserted_at
    )
    SELECT payment_operation_id, original_group_id, 'retained', retained_cents, CURRENT_TIMESTAMP
    FROM payment_dispositions
    WHERE retained_cents > 0
    """)

    execute("""
    INSERT INTO payment_settlements (
      payment_operation_id, group_id, disposition, amount_cents, inserted_at
    )
    SELECT payment_operation_id, original_group_id, 'converted_to_credit',
           converted_to_credit_cents, CURRENT_TIMESTAMP
    FROM payment_dispositions
    WHERE converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:payment_settlements)

    alter table(:payment_dispositions) do
      remove :transfer_participated
    end
  end
end
