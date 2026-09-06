defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :accounting_initialized, :boolean, null: false, default: false
    end

    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET status = (SELECT groups.status FROM groups WHERE groups.group_id = rooms.group_id),
        lodging_total_cents = nightly_rate_cents * (
          SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
          FROM groups WHERE groups.group_id = rooms.group_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT groups.rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * (
              SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
              FROM groups WHERE groups.group_id = rooms.group_id
            )
          ELSE CAST((nightly_rate_cents * (
            SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
            FROM groups WHERE groups.group_id = rooms.group_id
          ) * 20 + 50) / 100 AS INTEGER)
        END
    """)

    create table(:cash_payments, primary_key: false) do
      add :operation_id, :text, primary_key: true

      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :restrict),
        null: false

      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_payments, [:group_id])

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :text, on_delete: :delete_all),
        null: false

      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, references(:cash_payments, column: :operation_id, type: :text)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id, :id])

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :text
    end

    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :operation_id, type: :text, on_delete: :restrict)

      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_entitlements, [:credit_lot_id, :id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    GroupStay.Operations.backfill_room_accounting!()
  end

  def down do
    drop table(:credit_entitlements)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop_if_exists index(:credit_allocations, [:funding_operation_id])
    drop_if_exists index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    drop table(:cash_allocations)
    drop table(:cash_payments)

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
