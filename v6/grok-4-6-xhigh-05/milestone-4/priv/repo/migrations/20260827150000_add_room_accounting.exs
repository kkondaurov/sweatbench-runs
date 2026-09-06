defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:funding_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :fund_type, :string, null: false
      add :source_operation_id, :string
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :nilify_all)
      add :amount_cents, :integer, null: false
    end

    create index(:funding_allocations, [:group_id])
    create index(:funding_allocations, [:source_operation_id])
    create index(:funding_allocations, [:lot_id])

    create table(:payment_states, primary_key: false) do
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

    create index(:payment_states, [:group_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lot_id,
          references(:credit_lots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :position, :integer, null: false
    end

    create index(:credit_entitlements, [:lot_id])
    create index(:credit_entitlements, [:source_operation_id])
  end
end
