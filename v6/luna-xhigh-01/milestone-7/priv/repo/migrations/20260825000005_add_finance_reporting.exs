defmodule GroupStay.Repo.Migrations.AddFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_reporting_opening_cash) do
      add :property_id, :string, null: false
      add :held_cents, :integer, null: false
    end

    create unique_index(:finance_reporting_opening_cash, [:property_id])

    create table(:finance_reporting_opening_credit) do
      add :credit_lot_id, :integer, null: false
      add :available_cents, :integer, null: false
    end

    create unique_index(:finance_reporting_opening_credit, [:credit_lot_id])

    create table(:finance_events) do
      add :operation_id, :string, null: false
      add :posting_date, :date, null: false
      add :property_id, :string
      add :payment_operation_id, :string
      add :received_cents, :integer, null: false, default: 0
      add :transferred_in_cents, :integer, null: false, default: 0
      add :transferred_out_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :credit_lot_id, :integer
      add :credit_available_delta_cents, :integer, null: false, default: 0
      add :credit_issued_cents, :integer, null: false, default: 0
      add :credit_expired_cents, :integer, null: false, default: 0
      add :credit_consumed_cents, :integer, null: false, default: 0
      add :credit_revoked_cents, :integer, null: false, default: 0
      add :credit_absorbed_cents, :integer, null: false, default: 0
    end

    create index(:finance_events, [:posting_date, :property_id])
    create index(:finance_events, [:credit_lot_id, :posting_date])
    create index(:finance_events, [:payment_operation_id])
  end
end
