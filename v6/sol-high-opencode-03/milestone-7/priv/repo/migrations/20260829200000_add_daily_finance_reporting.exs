defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_states, primary_key: false) do
      add :id, :integer, primary_key: true
      add :start_operation_id, :text, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_reporting_states, [:start_operation_id])

    create table(:finance_cash_openings) do
      add :property_id, :text, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:finance_cash_openings, [:property_id])

    create table(:finance_movements) do
      add :operation_id, :text, null: false
      add :posting_on, :date, null: false
      add :scope, :text, null: false
      add :property_id, :text
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_movements, [:posting_on, :scope, :property_id, :kind])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_expiries, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), primary_key: true
      add :posting_on, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finance_credit_expiries, [:posting_on])
  end
end
