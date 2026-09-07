defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # A fixed key makes inception a database-enforced singleton.
    create table(:finance_inception, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :cash, :map, null: false
      add :credit_liability_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string
      add :category, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_movements, [:posting_on])
  end
end
