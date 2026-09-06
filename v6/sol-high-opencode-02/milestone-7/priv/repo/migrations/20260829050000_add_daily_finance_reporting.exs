defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_cash_openings) do
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:property_id])

    create table(:finance_credit_openings) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :available_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_credit_openings, [:credit_lot_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :scope, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posting_on, :scope])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_events) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :expires_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_events, [:posting_on, :id])
    create index(:finance_credit_events, [:credit_lot_id, :posting_on, :id])
    create index(:finance_credit_events, [:operation_id])
  end
end
