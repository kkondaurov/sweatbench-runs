defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :start_commit_sequence, :integer
      add :opening_cash_json, :text, null: false
      add :opening_credit_lots_json, :text, null: false
      add :opening_liability_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :text, null: false
      add :commit_sequence, :integer, null: false
      add :posting_on, :date, null: false
      add :category, :text, null: false
      add :movement, :text, null: false
      add :amount_cents, :integer, null: false
      add :property_id, :text
      add :payment_operation_id, :text
      add :lot_id, :integer
    end

    create index(:finance_movements, [:commit_sequence, :posting_on])
    create index(:finance_movements, [:payment_operation_id])
    create index(:finance_movements, [:lot_id])
  end
end
