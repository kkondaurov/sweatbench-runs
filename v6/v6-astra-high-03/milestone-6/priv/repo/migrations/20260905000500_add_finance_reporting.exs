defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_cents, :integer, null: false
    end

    create table(:finance_entries) do
      # Entries are written before the audit result, in the same transaction.
      add :operation_id, :string, null: false

      add :posting_on, :date, null: false
      add :property_id, :string
      add :movements, :map, null: false
    end

    create index(:finance_entries, [:posting_on])
  end
end
