defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :room_id, :string, null: false
      add :kind, :string, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, :binary_id
      add :converted_lot_id, :binary_id
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :fill_sequence, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:group_id, :disposition])
    create index(:room_allocations, [:converted_lot_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    flush()
    GroupStay.Funding.backfill_room_accounting()
  end

  def down do
    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:room_allocations, [:converted_lot_id])
    drop index(:room_allocations, [:group_id, :disposition])
    drop index(:room_allocations, [:payment_operation_id])
    drop index(:room_allocations, [:group_id])
    drop table(:room_allocations)
  end
end
