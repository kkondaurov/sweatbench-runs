defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET status = (
      SELECT groups.status
      FROM groups
      WHERE groups.id = rooms.group_id
    )
    """)

    execute("""
    UPDATE rooms
    SET lodging_total_cents =
      nightly_rate_cents * (
        SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
        FROM groups
        WHERE groups.id = rooms.group_id
      )
    """)

    execute("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (
        SELECT groups.rate_plan
        FROM groups
        WHERE groups.id = rooms.group_id
      ) = 'advance_purchase' THEN lodging_total_cents
      ELSE CAST(((lodging_total_cents * 20) + 50) / 100 AS INTEGER)
    END
    """)

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :allocation_type, :string, null: false
      add :operation_id, :string
      add :operation_record_id, :integer
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:operation_id])
    create index(:room_allocations, [:credit_lot_id])
    create index(:room_allocations, [:allocation_type, :disposition])
    create index(:room_allocations, [:operation_record_id, :id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
