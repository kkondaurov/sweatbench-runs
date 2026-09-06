defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
      add :allocations_ready, :boolean, null: false, default: false
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :fill_seq, :integer, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_allocations) do
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :apply_operation_id, :string
      add :lot_source_operation_id, :string, null: false
      add :amount_cents, :integer, null: false
      add :fill_seq, :integer, null: false
    end

    create index(:credit_allocations, [:group_id])
    create index(:credit_allocations, [:lot_source_operation_id])

    create table(:lot_entitlements) do
      add :lot_source_operation_id, :string, null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
    end

    create index(:lot_entitlements, [:lot_source_operation_id])
    create index(:lot_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:lot_entitlements)
    drop table(:credit_allocations)
    drop table(:cash_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
      remove :allocations_ready
    end
  end
end
