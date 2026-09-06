defmodule GroupStay.Repo.Migrations.RoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :source_operation_id, :string
      add :amount_cents, :integer, null: false
      add :status, :string, null: false
      add :fill_seq, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:source_operation_id])

    alter table(:credit_applications) do
      add :room_id, :string
      add :source_operation_id, :string
      add :fill_seq, :integer
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_lot_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :credit_lot_id, :binary_id, null: false
      add :source_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_entitlements, [:credit_lot_id])
    create index(:credit_lot_entitlements, [:source_operation_id])

    flush()

    GroupStay.Groups.backfill_room_accounting!()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:cash_allocations)

    alter table(:credit_applications) do
      remove :room_id
      remove :source_operation_id
      remove :fill_seq
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end
  end
end
