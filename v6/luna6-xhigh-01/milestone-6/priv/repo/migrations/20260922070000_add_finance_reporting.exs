defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_cash_by_property, :map, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_postings, primary_key: false) do
      add :operation_id, :string, primary_key: true
      add :posting_date, :date, null: false
      add :cash_movements, :map, null: false
      add :credit_movements, :map, null: false
      add :credit_lot_movements, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_postings, [:posting_date])
  end
end
