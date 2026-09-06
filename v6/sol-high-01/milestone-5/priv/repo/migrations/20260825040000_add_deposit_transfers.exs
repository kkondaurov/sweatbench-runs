defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:cash_payment_dispositions) do
      add :payment_operation_id, :string, null: false

      add :group_id,
          references(:groups,
            column: :group_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:cash_payment_dispositions, [
             :payment_operation_id,
             :group_id,
             :disposition
           ])

    create index(:cash_payment_dispositions, [:group_id])

    execute("""
    INSERT INTO cash_payment_dispositions
      (payment_operation_id, group_id, disposition, amount_cents)
    SELECT payment_operation_id, original_group_id, 'refunded', refunded_cents
      FROM cash_payments WHERE refunded_cents > 0
    UNION ALL
    SELECT payment_operation_id, original_group_id, 'retained', retained_cents
      FROM cash_payments WHERE retained_cents > 0
    UNION ALL
    SELECT payment_operation_id, original_group_id, 'converted_to_credit', converted_to_credit_cents
      FROM cash_payments WHERE converted_to_credit_cents > 0
    """)
  end

  def down do
    drop table(:cash_payment_dispositions)

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end
  end
end
