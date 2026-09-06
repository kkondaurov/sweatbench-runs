defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_opening_cash) do
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false
    end

    create unique_index(:finance_opening_cash, [:property_id])

    create table(:finance_opening_lots) do
      add :credit_lot_id, :integer, null: false
      add :remaining_cents, :integer, null: false
      add :expires_on, :date, null: false
    end

    create unique_index(:finance_opening_lots, [:credit_lot_id])

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
      add :issued_cents, :integer, null: false, default: 0
      add :expired_cents, :integer, null: false, default: 0
      add :consumed_cents, :integer, null: false, default: 0
      add :revoked_cents, :integer, null: false, default: 0
      add :absorbed_cents, :integer, null: false, default: 0
    end

    create index(:finance_movements, [:posting_on, :property_id])
    create index(:finance_movements, [:operation_id])

    create table(:finance_credit_events) do
      add :operation_id, :string, null: false
      add :credit_lot_id, :integer, null: false
      add :posting_on, :date, null: false
      add :available_delta_cents, :integer, null: false
    end

    create index(:finance_credit_events, [:credit_lot_id, :posting_on])
    create index(:finance_credit_events, [:operation_id])
  end
end
