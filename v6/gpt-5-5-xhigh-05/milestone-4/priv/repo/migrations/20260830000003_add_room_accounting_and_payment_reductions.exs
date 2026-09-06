defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE group_rooms
    SET
      status = (
        SELECT status
        FROM group_reservations
        WHERE group_reservations.id = group_rooms.group_reservation_id
      ),
      lodging_total_cents = nightly_rate_cents * (
        SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
        FROM group_reservations
        WHERE group_reservations.id = group_rooms.group_reservation_id
      ),
      deposit_due_cents =
        CASE (
          SELECT rate_plan
          FROM group_reservations
          WHERE group_reservations.id = group_rooms.group_reservation_id
        )
          WHEN 'advance_purchase' THEN nightly_rate_cents * (
            SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
            FROM group_reservations
            WHERE group_reservations.id = group_rooms.group_reservation_id
          )
          ELSE ((nightly_rate_cents * (
            SELECT CAST(julianday(departure_on) - julianday(arrival_on) AS INTEGER)
            FROM group_reservations
            WHERE group_reservations.id = group_rooms.group_reservation_id
          ) * 20) + 50) / 100
        END
    """)

    create index(:group_rooms, [:status])

    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_reservation_id,
          references(:group_reservations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :group_room_id, references(:group_rooms, type: :binary_id, on_delete: :restrict)
      add :payment_operation_id, :text
      add :disposition, :text, null: false
      add :amount_cents, :integer, null: false
      add :allocation_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_reservation_id])
    create index(:cash_allocations, [:group_room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:disposition])
    create index(:cash_allocations, [:group_reservation_id, :allocation_order])

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_applications) do
      add :group_room_id, references(:group_rooms, type: :binary_id, on_delete: :restrict)
      add :application_operation_id, :text
      add :status, :text, null: false, default: "held"
    end

    create index(:hotel_credit_applications, [:group_room_id])
    create index(:hotel_credit_applications, [:application_operation_id])
    create index(:hotel_credit_applications, [:status])

    create table(:hotel_credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :hotel_credit_lot_id,
          references(:hotel_credit_lots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :text
      add :principal_cents, :integer, null: false
      add :entitled_cents, :integer, null: false
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_entitlements, [:hotel_credit_lot_id])
    create index(:hotel_credit_entitlements, [:payment_operation_id])
  end

  def down do
    drop table(:hotel_credit_entitlements)

    drop index(:hotel_credit_applications, [:status])
    drop index(:hotel_credit_applications, [:application_operation_id])
    drop index(:hotel_credit_applications, [:group_room_id])

    alter table(:hotel_credit_applications) do
      remove :status
      remove :application_operation_id
      remove :group_room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop table(:cash_allocations)
    drop index(:group_rooms, [:status])

    alter table(:group_rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
