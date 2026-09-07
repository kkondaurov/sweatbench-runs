defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_periods) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:finance_cash_openings) do
      add :reporting_period_id,
          references(:finance_reporting_periods, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:reporting_period_id, :property_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date
      add :account, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :cash_funding_id, references(:cash_fundings, on_delete: :restrict)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:finance_movements, [:posting_date, :account, :classification])
    create index(:finance_movements, [:cash_funding_id, :classification])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_expiry_schedules) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :expires_on, :date, null: false
      add :opening_available_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_credit_expiry_schedules, [:credit_lot_id])

    create table(:finance_credit_expiry_adjustments) do
      add :credit_expiry_schedule_id,
          references(:finance_credit_expiry_schedules, on_delete: :delete_all),
          null: false

      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:finance_credit_expiry_adjustments, [
             :credit_expiry_schedule_id,
             :posting_date
           ])
  end
end
