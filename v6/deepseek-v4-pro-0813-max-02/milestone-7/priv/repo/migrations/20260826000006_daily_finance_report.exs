defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def up do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_report_positions, primary_key: false) do
      add :id, :integer, primary_key: true
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_report_positions, [:property_id])

    create table(:finance_lot_seeds, primary_key: false) do
      add :id, :integer, primary_key: true
      add :lot_id, :binary_id, null: false
      add :initial_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_lot_seeds, [:lot_id])

    create table(:finance_movements, primary_key: false) do
      add :id, :integer, primary_key: true
      add :category, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :lot_id, :binary_id
      add :amount_cents, :integer, null: false
      add :posting_date, :date, null: false
    end

    create index(:finance_movements, [:category, :posting_date])
    create index(:finance_movements, [:lot_id])
  end

  def down do
    drop table(:finance_movements)
    drop table(:finance_lot_seeds)
    drop table(:finance_report_positions)
    drop table(:finance_reporting)
  end
end
