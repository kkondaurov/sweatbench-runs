defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_json, :text, null: false
      add :opening_cash_details_json, :text, null: false
      add :opening_credit_cents, :integer, null: false
      add :opening_credit_lots_json, :text, null: false
    end

    create table(:finance_events) do
      add :operation_id, :string
      add :operation_type, :string, null: false
      add :posting_on, :date, null: false
      add :cash_json, :text, null: false
      add :credit_json, :text, null: false
      add :cash_details_json, :text, null: false
      add :credit_lot_deltas_json, :text, null: false
    end

    create index(:finance_events, [:posting_on])
    create index(:finance_events, [:operation_id])
  end
end
