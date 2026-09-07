defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:finance_cash_openings) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:reporting_start_id, :property_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :account, :string, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on, :account])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_availability_changes) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :operation_id, :string
      add :posting_on, :date, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_availability_changes, [:credit_lot_id, :posting_on])

    create table(:cash_settlements) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:cash_settlements, [:payment_operation_id])
    create index(:cash_settlements, [:group_id])

    # Older releases retained settlement totals per payment but not their post-transfer location.
    # Attribute those otherwise-unrecoverable historical rows to the original group. New
    # settlements preserve their exact location as they occur.
    execute("""
    INSERT INTO cash_settlements
      (payment_operation_id, group_id, kind, amount_cents, charged_back_cents,
       inserted_at, updated_at)
    SELECT payment_operation_id, group_id, kind, amount, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM (
        SELECT payment_operation_id, group_id, 'refund' kind, refunded_cents amount
          FROM payment_dispositions
        UNION ALL
        SELECT payment_operation_id, group_id, 'retention', retained_cents
          FROM payment_dispositions
        UNION ALL
        SELECT payment_operation_id, group_id, 'credit_conversion', converted_to_credit_cents
          FROM payment_dispositions
      )
     WHERE amount > 0
    """)
  end
end
