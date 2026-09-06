defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * (
      SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
      FROM groups WHERE groups.id = rooms.group_id
    )
    """)

    execute("""
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible'
        THEN CAST(lodging_total_cents / 5 AS INTEGER) +
          CASE WHEN lodging_total_cents % 5 >= 3 THEN 1 ELSE 0 END
      ELSE lodging_total_cents
    END
    """)

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :position, :integer
    end

    execute("UPDATE credit_allocations SET position = rowid")

    create table(:cash_payments) do
      add :operation_id, :string, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:operation_id])
    create index(:cash_payments, [:group_id])

    create table(:room_funding_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :operation_id, :string

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_funding_allocations, [:group_id, :id])
    create index(:room_funding_allocations, [:room_id, :id])
    create index(:room_funding_allocations, [:operation_id])
    create index(:room_funding_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :credit_cents, :integer, null: false
      add :revoked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()
    GroupStay.Operations.backfill_room_accounting()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_funding_allocations)
    drop table(:cash_payments)

    alter table(:credit_allocations) do
      remove :position
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end

    alter table(:groups) do
      remove :accounting_initialized
    end
  end
end
