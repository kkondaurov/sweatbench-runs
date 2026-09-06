defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_starts) do
      add :singleton, :boolean, null: false, default: true
      add :starts_on, :date, null: false
      add :source_operation_id, :string, null: false
    end

    create unique_index(:finance_reporting_starts, [:singleton])

    create table(:finance_reporting_cash_openings) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :property_id, :string, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_reporting_cash_openings, [:reporting_start_id, :property_id])

    create table(:finance_reporting_credit_openings) do
      add :reporting_start_id, references(:finance_reporting_starts, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :available_cents, :integer, null: false
      add :applied_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_reporting_credit_openings, [:reporting_start_id, :credit_lot_id])

    create table(:finance_reporting_entries) do
      add :operation_id, :string, null: false
      add :partner_operation_id, :integer, null: false
      add :ordinal, :integer, null: false
      add :posting_on, :date, null: false
      add :entry_type, :string, null: false
      add :property_id, :string
      add :category, :string
      add :amount_cents, :integer, null: false, default: 0
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :available_delta_cents, :integer, null: false, default: 0
      add :applied_delta_cents, :integer, null: false, default: 0
      add :expires_on, :date
    end

    create unique_index(:finance_reporting_entries, [:operation_id, :ordinal])
    create index(:finance_reporting_entries, [:posting_on, :partner_operation_id, :ordinal])
  end
end
