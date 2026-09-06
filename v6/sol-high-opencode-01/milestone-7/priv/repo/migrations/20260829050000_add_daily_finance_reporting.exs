defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting_settings) do
      add :singleton, :boolean, null: false, default: true
      add :starts_on_day, :integer, null: false
    end

    create unique_index(:finance_reporting_settings, [:singleton])

    create table(:finance_cash_opening_balances) do
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_opening_balances, [:property_id])

    create table(:finance_credit_opening_balances) do
      add :amount_cents, :integer, null: false
    end

    create table(:finance_movements) do
      add :operation_id, :string, null: false
      add :posting_on_day, :integer, null: false
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
    end

    create index(:finance_movements, [:posting_on_day])
    create index(:finance_movements, [:property_id, :posting_on_day])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_expiry_adjustments) do
      add :operation_id, :string, null: false
      add :posting_on_day, :integer, null: false
      add :expiration_on_day, :integer, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_expiry_adjustments, [:expiration_on_day])
    create index(:finance_credit_expiry_adjustments, [:operation_id])
  end
end
