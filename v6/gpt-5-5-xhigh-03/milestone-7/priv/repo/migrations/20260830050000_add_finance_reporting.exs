defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :singleton_key, :integer, null: false, default: 1
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_starts, [:singleton_key])
    create unique_index(:finance_reporting_starts, [:operation_id])

    create table(:finance_cash_opening_balances) do
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_opening_balances, [:property_id])

    create table(:finance_cash_movements) do
      add :posting_date, :date, null: false
      add :property_id, :string, null: false
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string
      add :cash_funding_id, references(:cash_fundings, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_cash_movements, [:posting_date])
    create index(:finance_cash_movements, [:property_id])
    create index(:finance_cash_movements, [:cash_funding_id])

    create table(:finance_credit_movements) do
      add :posting_date, :date, null: false
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string
      add :credit_lot_id, references(:guest_credit_lots, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:posting_date])
    create index(:finance_credit_movements, [:credit_lot_id])
  end
end
