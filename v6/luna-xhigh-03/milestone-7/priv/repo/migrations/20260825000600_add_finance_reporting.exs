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

    create table(:finance_events, primary_key: false) do
      add :operation_id, :string, primary_key: true
      add :posting_on, :date, null: false
      add :cash_movements_json, :text, null: false
      add :credit_movements_json, :text, null: false
      add :credit_lot_changes_json, :text, null: false
    end

    create index(:finance_events, [:posting_on])
  end
end
