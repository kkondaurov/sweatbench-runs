defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_inception, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :position, :map, null: false
    end

    create table(:finance_movements) do
      add :posting_on, :date, null: false
      add :property_id, :text
      add :classification, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posting_on])
  end
end
