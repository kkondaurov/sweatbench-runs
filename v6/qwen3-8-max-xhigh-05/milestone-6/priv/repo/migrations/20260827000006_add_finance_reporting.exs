defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :singleton, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_report_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_report_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :on_date, :date, null: false
      add :scope, :string, null: false
      add :property_id, :string
      add :entry, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_id, references(:credit_lots, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_report_movements, [:on_date])
    create index(:finance_report_movements, [:lot_id])
  end
end
