defmodule GroupStay.Repo.Migrations.RoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :payment_operation_id, :string
      add :disposition, :string, null: false, default: "held"
      add :seq, :integer, null: false

      add :group_id, references(:groups, column: :id, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_id, references(:rooms, column: :id, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lot_id,
          references(:credit_lots, column: :id, type: :binary_id, on_delete: :delete_all)

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:room_id])

    create table(:credit_lot_funding, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      add :lot_id,
          references(:credit_lots, column: :id, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:credit_lot_funding, [:lot_id])
    create index(:credit_lot_funding, [:payment_operation_id])

    # Execute the queued DDL now, before the backfill reads the new columns.
    flush()

    # Bring funding recorded before durable operation records existed into
    # room accounting without changing any aggregate balance.
    GroupStay.RoomAccounting.backfill()
  end

  def down do
    drop table(:credit_lot_funding)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :deposit_due_cents
    end
  end
end
