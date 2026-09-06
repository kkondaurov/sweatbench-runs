defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :singleton, :integer, null: false, default: 1
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :as_of_on, :date, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_starts, [:singleton])
    create unique_index(:finance_reporting_starts, [:operation_id])

    create table(:finance_opening_cash, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_cash, [:property_id])

    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :posting_date, :date, null: false
      add :book, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date, :book])

    create table(:finance_lot_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, :binary_id, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_lot_snapshots, [:credit_lot_id])

    create table(:finance_lot_remaining_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, :binary_id, null: false
      add :posting_date, :date, null: false
      add :delta_cents, :integer, null: false
      add :operation_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:finance_lot_remaining_changes, [:credit_lot_id, :posting_date])
  end
end
