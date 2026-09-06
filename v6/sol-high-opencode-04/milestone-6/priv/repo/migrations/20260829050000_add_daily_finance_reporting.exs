defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton, :boolean, null: false, default: true
      add :starts_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_opening_cash) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_opening_cash, [:finance_reporting_id, :property_id])

    create table(:finance_opening_credit) do
      add :finance_reporting_id, references(:finance_reporting, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_credit, [:finance_reporting_id, :credit_lot_id])

    create table(:finance_events) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :property_id, :string
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :expires_on, :integer
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:posting_on, :id])
    create index(:finance_events, [:credit_lot_id, :posting_on, :id])
    create index(:finance_events, [:operation_id])
  end
end
