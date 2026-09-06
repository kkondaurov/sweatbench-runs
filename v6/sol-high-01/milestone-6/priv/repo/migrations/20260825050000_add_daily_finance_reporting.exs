defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_cash_openings) do
      add :property_id, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:property_id])

    create table(:finance_cash_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :property_id, :string, null: false
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_cash_movements, [:operation_id, :property_id])
    create index(:finance_cash_movements, [:posting_on, :property_id])

    create table(:finance_credit_movements) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_credit_movements, [:operation_id])
    create index(:finance_credit_movements, [:posting_on])

    create table(:finance_credit_expiries) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :posting_on, :date, null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:finance_credit_expiries, [:credit_lot_id])
    create index(:finance_credit_expiries, [:posting_on])
  end
end
