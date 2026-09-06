defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :starts_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_reporting_cash_openings) do
      add :finance_reporting_id, references(:finance_reporting_settings, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_cash_openings, [:finance_reporting_id, :property_id])

    create table(:finance_reporting_credit_openings) do
      add :finance_reporting_id, references(:finance_reporting_settings, on_delete: :delete_all),
        null: false

      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false
      add :opening_available_cents, :integer, null: false
      add :opening_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting_credit_openings, [
             :finance_reporting_id,
             :hotel_credit_lot_id
           ])

    create table(:finance_movements) do
      add :finance_reporting_id, references(:finance_reporting_settings, on_delete: :delete_all),
        null: false

      add :partner_operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :entry_kind, :string, null: false
      add :property_id, :string
      add :classification, :string, null: false
      add :amount_cents, :integer, null: false
      add :available_delta_cents, :integer, null: false, default: 0
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)
      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:finance_reporting_id, :posting_on])
    create index(:finance_movements, [:cash_payment_id])
    create index(:finance_movements, [:hotel_credit_lot_id, :posting_on])
  end
end
