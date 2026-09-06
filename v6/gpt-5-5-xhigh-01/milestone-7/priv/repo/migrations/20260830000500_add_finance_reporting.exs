defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false, default: 0
      add :singleton, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_starts, [:operation_id])
    create unique_index(:finance_reporting_starts, [:singleton])

    create table(:finance_cash_opening_positions) do
      add :finance_reporting_start_id,
          references(:finance_reporting_starts, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_opening_positions, [
             :finance_reporting_start_id,
             :property_id
           ])

    create table(:finance_cash_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :property_id, :string, null: false
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_cash_movements, [:posting_date, :property_id])
    create index(:finance_cash_movements, [:operation_id])

    create table(:finance_credit_movements) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :nilify_all)
      add :movement_type, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:posting_date])
    create index(:finance_credit_movements, [:operation_id])
    create index(:finance_credit_movements, [:credit_lot_id])
  end
end
