defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts, primary_key: false) do
      add :singleton, :integer, primary_key: true, null: false
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_opening_positions) do
      add :scope, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :scope, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string, null: false

      add :lot_id, references(:credit_lots, column: :id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:scope, :classification])
    create index(:finance_movements, [:lot_id])
  end
end
