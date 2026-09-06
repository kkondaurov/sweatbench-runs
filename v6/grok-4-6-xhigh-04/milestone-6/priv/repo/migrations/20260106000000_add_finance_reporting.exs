defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :opening_credit_liability_cents, :integer, null: false
      add :opening_cash, :map, null: false, default: %{}
      add :opening_lots, {:array, :map}, null: false, default: []
      add :singleton, :integer, null: false, default: 1
    end

    create unique_index(:finance_reporting, [:singleton])
    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_events) do
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :classification, :string, null: false
      add :property_id, :string
      add :amount_cents, :integer, null: false
      add :lot_source_operation_id, :string
      add :lot_expires_on, :date
      add :operation_id, :string
    end

    create index(:finance_events, [:posting_date])
  end

  def down do
    drop table(:finance_events)
    drop table(:finance_reporting)
  end
end
