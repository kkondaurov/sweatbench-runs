defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_reporting, [:operation_id])

    create table(:finance_opening_cash) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_opening_cash, [:finance_reporting_id, :property_id])

    create table(:finance_opening_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :credit_lot_id, :binary_id, null: false
      add :expires_on, :date, null: false
      add :opening_available_cents, :integer, null: false
    end

    create unique_index(:finance_opening_credit_lots, [:finance_reporting_id, :credit_lot_id])

    create table(:finance_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :event_type, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false, default: 0
      add :credit_lot_id, :binary_id
      add :credit_lot_expires_on, :date
      add :available_delta_cents, :integer, null: false, default: 0
      add :applied_delta_cents, :integer, null: false, default: 0
    end

    create index(:finance_events, [:finance_reporting_id, :posting_on])
    create index(:finance_events, [:credit_lot_id])
  end
end
