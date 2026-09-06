defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :start_operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_cash_openings, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :amount_cents, :integer, null: false
    end

    create table(:finance_credit_openings, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        primary_key: true

      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on_days, :integer, null: false
    end

    create table(:finance_cash_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_movements, [:posting_on, :property_id])
    create index(:finance_cash_movements, [:operation_id])

    create table(:finance_credit_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_movements, [:posting_on])
    create index(:finance_credit_movements, [:operation_id])

    create table(:finance_credit_balance_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :effective_on, :date, null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :available_delta_cents, :integer, null: false
      add :applied_delta_cents, :integer, null: false
    end

    create index(:finance_credit_balance_events, [:credit_lot_id, :posting_on])
    create index(:finance_credit_balance_events, [:operation_id])
  end
end
