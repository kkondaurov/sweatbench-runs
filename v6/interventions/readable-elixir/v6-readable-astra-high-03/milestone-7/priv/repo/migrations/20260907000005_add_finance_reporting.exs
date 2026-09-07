defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
    end

    create table(:finance_entries) do
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :bigint, null: false
    end

    create index(:finance_entries, [:posted_on])
    create index(:finance_entries, [:operation_id])
  end
end
