defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_settings, [:singleton])

    create table(:finance_reporting_cash_openings) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_cash_openings, [:property_id])

    create table(:finance_reporting_credit_lot_openings) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :opening_available_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_credit_lot_openings, [:credit_lot_id])
    create index(:finance_reporting_credit_lot_openings, [:expires_on])

    create table(:finance_reporting_events) do
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_reporting_events, [:posted_on, :kind])
    create index(:finance_reporting_events, [:credit_lot_id, :posted_on])
    create index(:finance_reporting_events, [:operation_id])
  end
end
