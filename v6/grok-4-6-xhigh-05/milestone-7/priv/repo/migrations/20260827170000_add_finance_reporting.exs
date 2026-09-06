defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :start_operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_opening_cash) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_opening_cash, [:property_id])

    create table(:finance_cash_movements) do
      add :posted_on, :date, null: false
      add :property_id, :string, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string
    end

    create index(:finance_cash_movements, [:posted_on])
    create index(:finance_cash_movements, [:property_id])

    create table(:finance_credit_movements) do
      add :posted_on, :date, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string
    end

    create index(:finance_credit_movements, [:posted_on])

    create table(:finance_lots) do
      add :lot_id, :binary_id, null: false
      add :expires_on, :date, null: false
      add :opening_available_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_lots, [:lot_id])

    create table(:finance_lot_deltas) do
      add :lot_id, :binary_id, null: false
      add :posted_on, :date, null: false
      add :occurred_on, :date
      add :delta_cents, :integer, null: false
      add :operation_id, :string
    end

    create index(:finance_lot_deltas, [:lot_id])
    create index(:finance_lot_deltas, [:posted_on])

    create table(:payment_property_buckets) do
      add :payment_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_property_buckets, [:payment_operation_id, :property_id])
  end
end
