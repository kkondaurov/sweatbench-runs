defmodule GroupStay.Repo.Migrations.AddDailyFinanceReports do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_by_property, :map, null: false
      add :opening_credit_cents, :integer, null: false
    end

    create table(:finance_credit_openings) do
      add :credit_lot_id, :integer, null: false
      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_credit_openings, [:credit_lot_id])

    create table(:finance_cash_movements) do
      add :posting_on, :date, null: false
      add :property_id, :text, null: false
      add :classification, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_movements, [:posting_on, :property_id])

    create table(:finance_credit_events) do
      add :posting_on, :date, null: false
      add :credit_lot_id, :integer, null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_events, [:posting_on, :credit_lot_id])

    create table(:cash_payment_settlements) do
      add :payment_operation_id, :text, null: false
      add :group_id, :text, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_settlements, [:payment_operation_id, :group_id])
    create index(:cash_payment_settlements, [:group_id])

    execute """
    INSERT INTO cash_payment_settlements
      (payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents)
    SELECT payment_operation_id, group_id, refunded_cents, retained_cents, converted_to_credit_cents
    FROM cash_payments
    WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_to_credit_cents > 0
    """
  end
end
