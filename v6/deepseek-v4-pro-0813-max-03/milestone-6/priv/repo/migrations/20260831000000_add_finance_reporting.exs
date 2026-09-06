defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening, :map, null: false

      timestamps()
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_id, :integer
      add :expires_on, :date

      timestamps()
    end

    create index(:finance_movements, [:operation_id])
    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:lot_id])
  end
end
