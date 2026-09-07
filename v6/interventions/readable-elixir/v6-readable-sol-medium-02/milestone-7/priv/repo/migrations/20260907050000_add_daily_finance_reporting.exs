defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_configurations) do
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:finance_cash_openings) do
      add :configuration_id,
          references(:finance_reporting_configurations, on_delete: :delete_all),
          null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_cash_openings, [:configuration_id, :property_id])

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string

      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      add :credit_issued_cents, :integer, null: false, default: 0
      add :credit_expired_cents, :integer, null: false, default: 0
      add :credit_consumed_cents, :integer, null: false, default: 0
      add :credit_revoked_cents, :integer, null: false, default: 0
      add :credit_absorbed_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_on])
    create index(:finance_movements, [:property_id, :posting_on])
    create unique_index(:finance_movements, [:operation_id, :property_id])

    create table(:finance_credit_expiry_positions) do
      add :lot_id, references(:hotel_credit_lots, on_delete: :delete_all), null: false
      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_credit_expiry_positions, [:lot_id])
    create index(:finance_credit_expiry_positions, [:expires_on])
  end
end
