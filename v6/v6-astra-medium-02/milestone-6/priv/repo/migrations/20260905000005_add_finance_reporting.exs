defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening, :map, null: false
    end

    create table(:finance_movements) do
      add :posting_on, :date, null: false
      add :cash, :map, null: false
      add :credit, :map, null: false
    end

    create index(:finance_movements, [:posting_on])
  end
end
