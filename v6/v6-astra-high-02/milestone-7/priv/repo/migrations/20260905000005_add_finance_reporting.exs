defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_openings) do
      add :starts_on, :date, null: false
      add :cash, :map, null: false
      add :credit_liability_cents, :integer, null: false
    end

    create table(:finance_entries) do
      # The audit record is inserted later in the same transaction.
      add :operation_id, :string, null: false
      add :posted_on, :date, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_entries, [:posted_on])
    create index(:operations, [:type])
  end
end
