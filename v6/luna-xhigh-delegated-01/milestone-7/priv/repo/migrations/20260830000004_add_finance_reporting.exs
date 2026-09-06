defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_json, :text, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_report_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :property_id, :string
      add :related_payment_operation_id, :string

      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create index(:finance_report_movements, [:posting_date])
    create index(:finance_report_movements, [:related_payment_operation_id])

    create table(:finance_credit_expiries) do
      add :lot_id,
          references(:hotel_credit_lots, on_delete: :delete_all),
          null: false

      add :expires_on, :date, null: false
      add :scheduled_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_credit_expiries, [:lot_id])

    create table(:cash_settlements) do
      add :payment_operation_id, :string, null: false
      add :settlement_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_settlements, [:payment_operation_id])

    execute """
            INSERT INTO cash_settlements
              (payment_operation_id, settlement_operation_id, property_id, disposition, amount_cents)
            SELECT cash_payments.operation_id,
                   operations.operation_id,
                   groups.property_id,
                   'refunded',
                   cash_payments.refunded_cents
            FROM cash_payments
            JOIN operations
              ON operations.type = 'cancel_group'
             AND json_extract(operations.result_json, '$.status') = 'applied'
             AND json_extract(operations.result_json, '$.group_id') = cash_payments.group_id
            JOIN groups ON groups.group_id = cash_payments.group_id
            WHERE cash_payments.refunded_cents > 0

            UNION ALL

            SELECT cash_payments.operation_id,
                   operations.operation_id,
                   groups.property_id,
                   'retained',
                   cash_payments.retained_cents
            FROM cash_payments
            JOIN operations
              ON operations.type = 'cancel_group'
             AND json_extract(operations.result_json, '$.status') = 'applied'
             AND json_extract(operations.result_json, '$.group_id') = cash_payments.group_id
            JOIN groups ON groups.group_id = cash_payments.group_id
            WHERE cash_payments.retained_cents > 0

            UNION ALL

            SELECT cash_payments.operation_id,
                   operations.operation_id,
                   groups.property_id,
                   'converted',
                   cash_payments.converted_to_credit_cents
            FROM cash_payments
            JOIN operations
              ON operations.type = 'cancel_group'
             AND json_extract(operations.result_json, '$.status') = 'applied'
             AND json_extract(operations.result_json, '$.group_id') = cash_payments.group_id
            JOIN groups ON groups.group_id = cash_payments.group_id
            WHERE cash_payments.converted_to_credit_cents > 0
            """,
            "DELETE FROM cash_settlements"
  end
end
