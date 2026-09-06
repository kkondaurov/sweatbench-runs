defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      # A unique singleton makes starting reporting safe if two gateway requests race.
      add :singleton, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_starts, [:singleton])

    create table(:finance_cash_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:reporting_start_id, :property_id])

    # Expiry is evaluated from a lot's available balance at the end of its expiry date. Keeping
    # this start-of-report snapshot lets that balance be reconstructed without mutating a lot
    # while a report is read.
    create table(:finance_credit_lot_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :opening_available_cents, :integer, null: false
      add :expires_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_credit_lot_openings, [:reporting_start_id, :credit_lot_id])
    create index(:finance_credit_lot_openings, [:expires_on])

    create table(:finance_cash_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :property_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :posted_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_cash_movements, [:posted_on, :property_id, :kind])

    create table(:finance_credit_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :posted_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_movements, [:posted_on, :kind])

    create table(:finance_credit_lot_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :available_delta_cents, :integer, null: false
      add :posted_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_lot_changes, [:credit_lot_id, :posted_on])
  end
end
