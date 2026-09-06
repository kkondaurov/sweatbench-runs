defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :singleton_key, :integer, null: false, default: 1
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_reporting, [:singleton_key])

    create table(:finance_opening_cash) do
      add :reporting_id, references(:finance_reporting, on_delete: :delete_all), null: false
      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:finance_opening_cash, [:reporting_id, :property_id])

    create table(:finance_movements) do
      add :posting_date, :date, null: false
      add :operation_id, :string, null: false
      add :property_id, :string
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:finance_movements, [:posting_date])
    create index(:finance_movements, [:operation_id])

    create table(:credit_expiry_schedules, primary_key: false) do
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :expires_on, :date, null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:credit_expiry_schedules, [:expires_on])

    create table(:cash_dispositions) do
      add :funding_id, references(:fundings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_dispositions, [:funding_id, :property_id])
  end
end
