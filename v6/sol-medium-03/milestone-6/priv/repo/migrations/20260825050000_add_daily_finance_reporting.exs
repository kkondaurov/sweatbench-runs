defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :credit_opening_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:finance_cash_openings) do
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_cash_openings, [:property_id])

    create table(:finance_credit_lot_openings) do
      add :credit_lot_id, :integer, null: false
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:finance_credit_lot_openings, [:credit_lot_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :account, :string, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:finance_movements, [:posting_date, :account])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_lot_events) do
      add :credit_lot_id, :integer, null: false
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :expires_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:finance_credit_lot_events, [:credit_lot_id, :posting_date])
    create index(:finance_credit_lot_events, [:operation_id])
  end
end
