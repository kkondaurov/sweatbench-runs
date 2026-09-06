defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_json, :text, null: false
      add :opening_credit_liability_cents, :integer, null: false
      add :opening_credit_lots_json, :text, null: false
    end

    create table(:finance_events) do
      add :operation_id, :string, null: false
      add :operation_type, :string, null: false
      add :posted_on, :date, null: false
      add :cash_json, :text, null: false
      add :credit_json, :text, null: false
      add :credit_activity_json, :text, null: false
    end

    create unique_index(:finance_events, [:operation_id])
    create index(:finance_events, [:posted_on, :id])
  end
end
