defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :room_accounting_initialized, :boolean, null: false, default: true
    end

    # Rows created before this release have only aggregate funding state. The
    # application backfills those rows transactionally before their next write.
    execute "UPDATE groups SET room_accounting_initialized = 0"

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :room_id, :text
      add :operation_id, :text
    end

    create table(:cash_payments) do
      add :payment_operation_id, :text, null: false
      add :group_id, :text, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_id])

    create table(:cash_allocations) do
      add :group_id, :text, null: false
      add :room_id, :text, null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:hotel_credit_lot_entitlements) do
      add :lot_id, references(:hotel_credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :text
      add :amount_cents, :integer, null: false
    end

    create index(:hotel_credit_lot_entitlements, [:lot_id])
    create index(:hotel_credit_lot_entitlements, [:payment_operation_id])

    execute(
      fn ->
        GroupStay.Groups.backfill_room_accounting()
      end,
      fn ->
        :ok
      end
    )
  end
end
