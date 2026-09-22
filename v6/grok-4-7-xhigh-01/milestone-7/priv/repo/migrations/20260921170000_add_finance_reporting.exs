defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton, :integer, null: false, default: 1
      add :operation_id, :string, null: false
      add :starts_on, :date, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton])

    create table(:finance_opening_cash) do
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_cash, [:property_id])

    create table(:finance_movements) do
      add :posting_on, :date, null: false
      add :property_id, :string
      add :bucket, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on, :bucket])

    create table(:finance_credit_events) do
      add :credit_lot_id, :binary_id, null: false
      add :posting_on, :date, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:finance_credit_events, [:credit_lot_id, :posting_on])
  end
end
