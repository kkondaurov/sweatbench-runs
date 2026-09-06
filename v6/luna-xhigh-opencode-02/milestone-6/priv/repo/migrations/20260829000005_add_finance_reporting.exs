defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_cents, :integer, null: false
      add :opening_credit_lots, :map, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :cash_movements, :map, null: false
      add :credit_events, :map, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:finance_movements, [:operation_id])
    create index(:finance_movements, [:posting_on])
  end
end
