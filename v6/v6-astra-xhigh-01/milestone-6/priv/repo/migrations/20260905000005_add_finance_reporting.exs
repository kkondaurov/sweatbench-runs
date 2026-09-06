defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    # A singleton, created only by the first successful start operation.
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true, check: %{name: "singleton", expr: "id = 1"}
      add :starts_on, :date, null: false
    end

    create table(:finance_entries) do
      # The enclosing transaction inserts the durable operation after its effects.
      add :operation_id, :string, null: false
      add :date, :date, null: false
      add :property_id, :string
      add :category, :string, null: false
      add :amount_cents, :bigint, null: false
    end

    create index(:finance_entries, [:date])
  end
end
