defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:cash_payment_property_dispositions, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :property_id, :string, primary_key: true
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end

    create index(:cash_payment_property_dispositions, [:property_id])

    execute("""
    INSERT INTO cash_payment_property_dispositions
      (payment_operation_id, property_id, refunded_cents, retained_cents, converted_to_credit_cents)
    SELECT payments.operation_id, groups.property_id, payments.refunded_cents,
           payments.retained_cents, payments.converted_to_credit_cents
    FROM cash_payment_records AS payments
    JOIN groups ON groups.group_id = payments.group_id
    WHERE payments.refunded_cents > 0
       OR payments.retained_cents > 0
       OR payments.converted_to_credit_cents > 0
    """)

    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_reporting_openings, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :held_cents, :integer, null: false
    end

    create table(:finance_reporting_credit_openings, primary_key: false) do
      add :lot_id, :integer, primary_key: true
      add :source_operation_id, :string, null: false
      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create table(:finance_events) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :cash_movements, :map, null: false
      add :credit_movements, :map, null: false
      add :credit_lot_changes, :map, null: false
    end

    create unique_index(:finance_events, [:operation_id])
    create index(:finance_events, [:posting_on, :id])
  end

  def down do
    drop table(:finance_events)
    drop table(:finance_reporting_credit_openings)
    drop table(:finance_reporting_openings)
    drop table(:finance_reporting)
    drop table(:cash_payment_property_dispositions)
  end
end
