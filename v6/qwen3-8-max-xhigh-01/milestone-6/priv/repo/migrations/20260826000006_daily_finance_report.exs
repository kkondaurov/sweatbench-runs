defmodule GroupStay.Repo.Migrations.DailyFinanceReport do
  use Ecto.Migration

  def change do
    # At most one finance-reporting start is ever applied. The row is inserted
    # under a fixed primary key so concurrent starts cannot both commit.
    create table(:finance_reporting_starts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:finance_opening_cash, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_opening_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, references(:credit_lots, type: :binary_id), null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:credit_lot_id])
    create index(:finance_opening_lots, [:credit_lot_id])
  end
end
