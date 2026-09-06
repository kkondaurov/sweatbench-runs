defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton_key, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_reporting, [:singleton_key])
    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_cash_openings) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:reporting_id, :property_id])

    create table(:finance_credit_openings) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_credit_openings, [:reporting_id, :credit_lot_id])

    create table(:finance_postings) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :domain, :string, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :reference_id, :string
      add :line_number, :integer, null: false
    end

    create unique_index(:finance_postings, [:operation_id, :line_number])
    create index(:finance_postings, [:posting_on])
    create index(:finance_postings, [:reference_id, :classification])

    create table(:finance_credit_events) do
      add :operation_id, :string, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :posting_on, :date, null: false
      add :effective_on, :date, null: false
      add :event_type, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_events, [:credit_lot_id, :posting_on])

    create table(:finance_cash_dispositions) do
      add :operation_id, :string, null: false
      add :payment_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_dispositions, [:payment_operation_id, :classification])
  end
end
