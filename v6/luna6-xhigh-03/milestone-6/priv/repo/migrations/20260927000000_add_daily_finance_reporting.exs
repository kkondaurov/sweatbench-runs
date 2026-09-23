defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_report_opening_cash, primary_key: false) do
      add :property_id, :text, primary_key: true
      add :held_cents, :integer, null: false
    end

    create table(:finance_report_opening_credit, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, on_delete: :nothing), primary_key: true
      add :expires_on, :date, null: false
      add :available_cents, :integer, null: false
    end

    create table(:finance_report_entries) do
      add :posting_on, :date, null: false
      add :property_id, :text
      add :credit_lot_id, :integer
      add :movement_type, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_report_entries, [:posting_on, :movement_type])
    create index(:finance_report_entries, [:property_id, :posting_on])
    create index(:finance_report_entries, [:credit_lot_id, :posting_on])
  end
end
