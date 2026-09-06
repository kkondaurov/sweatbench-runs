defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source_operation_id, :string
      add :lot_id, references(:credit_lots, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create table(:payment_dispositions) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :lot_id, references(:credit_lots, on_delete: :delete_all)

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:source_operation_id])
    create index(:room_allocations, [:lot_id])
    create index(:payment_dispositions, [:group_id])
    create index(:payment_dispositions, [:payment_operation_id])
    create index(:payment_dispositions, [:kind])
    create index(:payment_dispositions, [:lot_id])

    flush()

    GroupStay.Accounting.backfill_rooms!()
    GroupStay.Accounting.reconcile_all!()
  end
end
