defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posting_on])
  end
end
