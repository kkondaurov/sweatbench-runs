defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_settings, [:singleton])

    create table(:finance_reporting_cash_openings) do
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_cash_openings, [:property_id])

    # Keep the reporting inception's lot-level state as well as its aggregate
    # liability.  The lot state lets a report show a later automatic expiry
    # without making a read mutate a credit lot.
    create table(:finance_reporting_credit_lot_openings, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :nothing),
        primary_key: true

      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_reporting_movements) do
      add :operation_id, :string
      add :posting_on, :date, null: false
      add :currency, :string, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_reporting_movements, [:posting_on, :currency])
    create index(:finance_reporting_movements, [:operation_id])

    # These are balance transfers inside a credit lot.  They are not report
    # movements themselves, but they determine how much unused credit expires.
    create table(:finance_reporting_credit_lot_events) do
      add :operation_id, :string

      add :credit_lot_id,
          references(:credit_lots, type: :binary_id, on_delete: :nothing),
          null: false

      add :posting_on, :date, null: false
      add :available_delta_cents, :integer, null: false, default: 0
      add :applied_delta_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_reporting_credit_lot_events, [:credit_lot_id, :posting_on])
    create index(:finance_reporting_credit_lot_events, [:operation_id])
  end
end
