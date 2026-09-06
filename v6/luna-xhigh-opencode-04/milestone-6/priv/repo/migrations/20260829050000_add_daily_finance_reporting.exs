defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def change do
    create table(:finance_reporting) do
      add :starts_on, :date, null: false
      add :opening_cash, :map, null: false
      add :opening_credit_liability_cents, :integer, null: false
      add :opening_credit_lots, :map, null: false
    end

    create table(:finance_report_events) do
      add :operation_id, :string, null: false
      add :posting_on, :date, null: false
      add :cash_movements, :map, null: false
      add :credit_movements, :map, null: false
      add :credit_lot_changes, :map, null: false
    end

    create unique_index(:finance_report_events, [:operation_id])
    create index(:finance_report_events, [:posting_on])

    create table(:payment_property_accountings) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_property_accountings, [:payment_operation_id, :group_id])
    create index(:payment_property_accountings, [:payment_operation_id])
  end
end
