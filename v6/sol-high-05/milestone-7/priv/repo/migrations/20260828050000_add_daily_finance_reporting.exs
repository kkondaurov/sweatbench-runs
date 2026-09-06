defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:finance_opening_cash, primary_key: false) do
      add :property_id, :string, primary_key: true
      add :opening_held_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :scope, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:scope, :property_id, :posting_on])

    create unique_index(
             :finance_movements,
             [:operation_id, :scope, :property_id, :classification],
             name: :finance_movements_operation_classification_index
           )

    create table(:credit_expiry_schedules, primary_key: false) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), primary_key: true
      add :posting_on, :date, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:credit_expiry_schedules, [:posting_on])
  end
end
