defmodule GroupStay.Repo.Migrations.AddDepositTransferAccounting do
  use Ecto.Migration

  def up do
    alter table(:payment_cash_dispositions) do
      add :transferred, :boolean, null: false, default: false
    end

    create table(:payment_cash_settlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_pk_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_cash_settlements, [:payment_operation_id, :group_pk_id])
    create index(:payment_cash_settlements, [:group_pk_id])

    execute("""
    INSERT INTO payment_cash_settlements (
      id,
      group_pk_id,
      payment_operation_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents,
      inserted_at,
      updated_at
    )
    SELECT
      lower(hex(randomblob(4))) || '-' ||
      lower(hex(randomblob(2))) || '-' ||
      lower(hex(randomblob(2))) || '-' ||
      lower(hex(randomblob(2))) || '-' ||
      lower(hex(randomblob(6))),
      group_pk_id,
      payment_operation_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents,
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    FROM payment_cash_dispositions
    WHERE refunded_cents > 0
       OR retained_cents > 0
       OR converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:payment_cash_settlements)

    alter table(:payment_cash_dispositions) do
      remove :transferred
    end
  end
end
