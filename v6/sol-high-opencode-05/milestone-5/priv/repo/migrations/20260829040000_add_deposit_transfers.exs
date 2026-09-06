defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create index(:room_funding_allocations, [:source_operation_id, :allocation_order])

    create table(:cash_payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false

      add :group_record_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_dispositions, [
             :payment_operation_id,
             :group_record_id
           ])

    create index(:cash_payment_dispositions, [:group_record_id])

    execute("""
    INSERT INTO cash_payment_dispositions (
      id,
      payment_operation_id,
      group_record_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents
    )
    SELECT
      lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
        substr(lower(hex(randomblob(2))), 2) || '-' ||
        substr('89ab', abs(random()) % 4 + 1, 1) ||
        substr(lower(hex(randomblob(2))), 2) || '-' || lower(hex(randomblob(6))),
      payment_operation_id,
      group_record_id,
      refunded_cents,
      retained_cents,
      converted_to_credit_cents
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:cash_payment_dispositions)
    drop index(:room_funding_allocations, [:source_operation_id, :allocation_order])

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end
  end
end
