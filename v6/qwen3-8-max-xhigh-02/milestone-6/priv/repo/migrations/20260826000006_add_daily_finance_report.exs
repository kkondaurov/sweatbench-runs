defmodule GroupStay.Repo.Migrations.AddDailyFinanceReport do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :starts_on, :date, null: false
      add :operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps()
    end

    create table(:finance_opening_cash_positions) do
      add :reporting_start_id,
          references(:finance_reporting_starts, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps()
    end

    create unique_index(:finance_opening_cash_positions, [:reporting_start_id, :property_id])

    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :scope, :string, null: false
      add :property_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_id, references(:credit_lots, on_delete: :nilify_all)

      timestamps()
    end

    create index(:finance_movements, [:scope, :posting_date])
    create index(:finance_movements, [:property_id])
    create index(:finance_movements, [:lot_id])
  end
end
