defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :room_accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :room_id, :string
      add :operation_id, :string
    end

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:group_id])

    create table(:hotel_credit_entitlements) do
      add :credit_lot_id,
          references(:hotel_credit_lots, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :clawed_back_cents, :integer, null: false, default: 0
    end

    create index(:hotel_credit_entitlements, [:credit_lot_id])
    create index(:hotel_credit_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:hotel_credit_entitlements)
    drop table(:cash_payments)
    drop table(:cash_allocations)

    alter table(:hotel_credit_allocations) do
      remove :operation_id
      remove :room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :status
    end

    alter table(:groups) do
      remove :room_accounting_initialized
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end
end
