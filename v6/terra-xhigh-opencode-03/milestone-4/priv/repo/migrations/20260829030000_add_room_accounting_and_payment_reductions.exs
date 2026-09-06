defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.id = rooms.group_db_id),
        lodging_total_cents = (
          SELECT CAST((julianday(departure_on) - julianday(arrival_on)) AS INTEGER) * rooms.nightly_rate_cents
          FROM groups WHERE groups.id = rooms.group_db_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_db_id) = 'cancelled' THEN 0
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_db_id) = 'advance_purchase' THEN
            (SELECT CAST((julianday(departure_on) - julianday(arrival_on)) AS INTEGER) * rooms.nightly_rate_cents
             FROM groups WHERE groups.id = rooms.group_db_id)
          ELSE
            ((SELECT CAST((julianday(departure_on) - julianday(arrival_on)) AS INTEGER) * rooms.nightly_rate_cents
              FROM groups WHERE groups.id = rooms.group_db_id) * 20 + 50) / 100
        END
    """)

    execute("""
    UPDATE groups
    SET lodging_total_cents = 0,
        deposit_due_cents = 0,
        deposit_paid_cents = 0,
        cash_paid_cents = 0,
        credit_paid_cents = 0
    WHERE status = 'cancelled'
    """)

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments) do
      add :payment_operation_id, :string, null: false
      add :group_db_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_db_id])

    create table(:room_cash_allocations) do
      add :group_db_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_db_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_cash_allocations, [:group_db_id])
    create index(:room_cash_allocations, [:payment_operation_id])

    create table(:room_credit_allocations) do
      add :group_db_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_db_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_credit_allocations, [:group_db_id])
    create index(:room_credit_allocations, [:credit_lot_id])

    create table(:credit_lot_entitlements) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_entitlements, [:credit_lot_id])
    create index(:credit_lot_entitlements, [:payment_operation_id])

    flush()
    GroupStay.Reservations.backfill_legacy_room_accounting()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:room_credit_allocations)
    drop table(:room_cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end
end
