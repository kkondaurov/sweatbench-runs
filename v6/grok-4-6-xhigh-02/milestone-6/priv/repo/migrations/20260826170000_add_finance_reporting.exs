defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :start_operation_id, :string, null: false
      add :opening_liability_cents, :integer, null: false
      add :opening_cash, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:start_operation_id])

    create table(:finance_events) do
      add :posted_on, :date, null: false
      add :operation_id, :string
      add :property_id, :string
      add :kind, :string, null: false
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_source_operation_id, :string
      add :expires_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:posted_on])
    create index(:finance_events, [:kind])
    create index(:finance_events, [:lot_source_operation_id])

    create table(:finance_lot_openings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_operation_id, :string, null: false
      add :expires_on, :date, null: false
      add :remaining_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_lot_openings, [:source_operation_id])

    create table(:cash_settlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false
      add :property_id, :string, null: false
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_settlements, [
             :payment_operation_id,
             :property_id,
             :disposition
           ])

    create index(:cash_settlements, [:payment_operation_id])
  end
end
