defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, :string
      add :funding_operation_id, :string
    end

    create table(:cash_allocations) do
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :room_index, :integer, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_index])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      add :charged_back, :boolean, null: false, default: false
    end

    create index(:cash_payments, [:group_id])

    create table(:credit_lot_contributions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :clawed_back_cents, :integer, null: false, default: 0
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])
  end

  def down do
    drop table(:credit_lot_contributions)
    drop table(:cash_payments)
    drop table(:cash_allocations)

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end
end
