defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :posted_on, :date, null: false
      add :property_id, :text
      add :classification, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posted_on])
  end
end
