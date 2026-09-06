defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create index(:groups, [:guest_id])

    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true, null: false
      add :starts_on, :date, null: false
      # JSON preserves company totals that can exceed SQLite's integer range.
      add :opening, :map, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :cash, :map, null: false
      add :credit, :map, null: false
    end

    create unique_index(:finance_movements, [:operation_id, :posted_on])
    create index(:finance_movements, [:posted_on])
  end
end
