defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting_starts, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps()
    end

    create table(:finance_cash_openings) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:finance_cash_openings, [:reporting_start_id, :property_id])

    create table(:finance_postings) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :operation_id, :string
      add :posting_on, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:finance_postings, [:reporting_start_id, :posting_on, :property_id, :kind])

    create table(:finance_credit_expiry_schedules) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:finance_credit_expiry_schedules, [:reporting_start_id, :credit_lot_id])
    create index(:finance_credit_expiry_schedules, [:reporting_start_id, :expires_on])

    create table(:cash_payment_dispositions) do
      add :payment_operation_id,
          references(:cash_payments,
            column: :operation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :property_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:cash_payment_dispositions, [:payment_operation_id])

    # Earlier releases did not persist a settlement-property reference. Refunds and retentions
    # retain their original-property fallback; converted cash can be reconstructed exactly from
    # the credit lot's cancellation group and is handled separately below.
    execute("""
    INSERT INTO cash_payment_dispositions (
      payment_operation_id, property_id, kind, amount_cents, inserted_at, updated_at
    )
    SELECT cash_payments.operation_id, groups.property_id, 'refunded', cash_payments.refunded_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM cash_payments
    JOIN groups ON groups.group_id = cash_payments.group_id
    WHERE cash_payments.refunded_cents > 0
    """)

    execute("""
    INSERT INTO cash_payment_dispositions (
      payment_operation_id, property_id, kind, amount_cents, inserted_at, updated_at
    )
    SELECT cash_payments.operation_id, groups.property_id, 'retained', cash_payments.retained_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM cash_payments
    JOIN groups ON groups.group_id = cash_payments.group_id
    WHERE cash_payments.retained_cents > 0
    """)

    execute("""
    INSERT INTO cash_payment_dispositions (
      payment_operation_id, property_id, kind, amount_cents, inserted_at, updated_at
    )
    SELECT credit_lot_contributions.payment_operation_id, groups.property_id,
           'converted_to_credit', SUM(credit_lot_contributions.cash_amount_cents),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM credit_lot_contributions
    JOIN credit_lots ON credit_lots.id = credit_lot_contributions.credit_lot_id
    JOIN partner_operations ON partner_operations.operation_id = credit_lots.source_operation_id
    JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
    WHERE credit_lot_contributions.payment_operation_id IS NOT NULL
    GROUP BY credit_lot_contributions.payment_operation_id, groups.property_id
    """)

    execute("""
    INSERT INTO cash_payment_dispositions (
      payment_operation_id, property_id, kind, amount_cents, inserted_at, updated_at
    )
    SELECT cash_payments.operation_id, groups.property_id, 'converted_to_credit',
           cash_payments.converted_to_credit_cents - COALESCE((
             SELECT SUM(credit_lot_contributions.cash_amount_cents)
             FROM credit_lot_contributions
             WHERE credit_lot_contributions.payment_operation_id = cash_payments.operation_id
           ), 0), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM cash_payments
    JOIN groups ON groups.group_id = cash_payments.group_id
    WHERE cash_payments.converted_to_credit_cents > COALESCE((
      SELECT SUM(credit_lot_contributions.cash_amount_cents)
      FROM credit_lot_contributions
      WHERE credit_lot_contributions.payment_operation_id = cash_payments.operation_id
    ), 0)
    """)
  end

  def down do
    drop table(:cash_payment_dispositions)
    drop table(:finance_credit_expiry_schedules)
    drop table(:finance_postings)
    drop table(:finance_cash_openings)
    drop table(:finance_reporting_starts)
  end
end
