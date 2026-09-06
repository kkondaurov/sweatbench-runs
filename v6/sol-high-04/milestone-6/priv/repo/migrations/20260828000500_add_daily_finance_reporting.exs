defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reportings) do
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reportings, [:operation_id])

    create table(:finance_cash_openings) do
      add :finance_reporting_id, references(:finance_reportings, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:finance_reporting_id, :property_id])

    create table(:finance_cash_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string, null: false
      add :category, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_cash_movements, [:posting_on, :property_id])
    create index(:finance_cash_movements, [:operation_id])

    create table(:finance_credit_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :category, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:posting_on])
    create index(:finance_credit_movements, [:operation_id])

    create table(:finance_credit_expiry_positions) do
      add :finance_reporting_id, references(:finance_reportings, on_delete: :delete_all),
        null: false

      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_expiry_positions, [:expires_on])

    create table(:finance_credit_expiry_adjustments) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_expiry_adjustments, [:expires_on, :posting_on])
    create index(:finance_credit_expiry_adjustments, [:operation_id])
  end
end
