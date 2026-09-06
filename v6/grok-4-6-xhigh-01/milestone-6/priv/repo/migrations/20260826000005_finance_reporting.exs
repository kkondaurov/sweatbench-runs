defmodule GroupStay.Repo.Migrations.FinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :string, primary_key: true
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :opening, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :lot_id, :string
      add :expires_on, :date
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:kind])
  end
end
