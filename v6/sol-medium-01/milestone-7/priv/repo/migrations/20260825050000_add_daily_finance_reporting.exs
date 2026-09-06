defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:finance_cash_openings) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:finance_cash_openings, [:finance_reporting_id, :property_id])

    create table(:finance_lot_openings) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :available_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:finance_lot_openings, [:finance_reporting_id, :credit_lot_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:finance_movements, [:posting_on, :kind])
    create index(:finance_movements, [:credit_lot_id, :posting_on])
    create index(:finance_movements, [:operation_id])
  end
end
