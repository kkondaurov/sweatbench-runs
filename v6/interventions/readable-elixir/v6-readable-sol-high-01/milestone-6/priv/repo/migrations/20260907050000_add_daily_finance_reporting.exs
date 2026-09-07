defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts, primary_key: false) do
      # Reporting can be started only once for this service. A fixed primary key
      # makes that invariant durable without relying on application locks.
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create table(:finance_cash_opening_balances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:finance_cash_opening_balances, [:property_id])

    create table(:finance_credit_lot_opening_balances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_record_id, :binary_id, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false
      add :allocated_cents, :integer, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:finance_credit_lot_opening_balances, [:credit_lot_record_id])

    create table(:finance_operation_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :cash, :map, null: false
      add :credit, :map, null: false
      add :credit_lot_deltas, :map, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:finance_operation_movements, [:operation_id])
    create index(:finance_operation_movements, [:posting_date])
  end
end
