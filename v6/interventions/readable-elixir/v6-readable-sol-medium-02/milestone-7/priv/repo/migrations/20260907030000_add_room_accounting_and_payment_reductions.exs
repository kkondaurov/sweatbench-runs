defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:reservation_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:group_reservations) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    # Existing allocation rows are split into room-level rows by the backfill below.
    alter table(:hotel_credit_allocations) do
      add :room_id, references(:reservation_rooms, on_delete: :restrict)
    end

    create index(:hotel_credit_allocations, [:room_id])

    create table(:cash_payment_accountings) do
      add :payment_operation_id, :string, null: false
      add :operation_record_id, references(:partner_operation_records, on_delete: :restrict)

      add :group_id,
          references(:group_reservations,
            column: :group_id,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payment_accountings, [:payment_operation_id])
    create unique_index(:cash_payment_accountings, [:operation_record_id])
    create index(:cash_payment_accountings, [:group_id])

    create table(:room_cash_allocations) do
      add :room_id, references(:reservation_rooms, on_delete: :restrict), null: false
      add :payment_accounting_id, references(:cash_payment_accountings, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:room_cash_allocations, [:room_id])
    create index(:room_cash_allocations, [:payment_accounting_id])

    create table(:credit_lot_entitlements) do
      add :lot_id, references(:hotel_credit_lots, on_delete: :restrict), null: false

      add :payment_accounting_id, references(:cash_payment_accountings, on_delete: :restrict),
        null: false

      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_entitlements, [:payment_accounting_id])
    create unique_index(:credit_lot_entitlements, [:lot_id, :payment_accounting_id])

    backfill_room_economics()
    backfill_payment_accounting()
    backfill_credit_entitlements()
    backfill_active_cash_allocations()
    backfill_active_credit_allocations()
    clear_cancelled_group_totals()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:room_cash_allocations)
    drop table(:cash_payment_accountings)

    drop index(:hotel_credit_allocations, [:room_id])

    alter table(:hotel_credit_allocations) do
      remove :room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_reservations) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:reservation_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill_room_economics do
    execute("""
    UPDATE reservation_rooms
       SET status = (SELECT status FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id),
           lodging_total_cents = nightly_rate_cents *
             CAST(julianday((SELECT departure_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) -
                  julianday((SELECT arrival_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) AS INTEGER),
           deposit_due_cents = CASE
             WHEN (SELECT rate_plan FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id) = 'advance_purchase'
               THEN nightly_rate_cents * CAST(julianday((SELECT departure_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) - julianday((SELECT arrival_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) AS INTEGER)
             ELSE CAST((nightly_rate_cents * CAST(julianday((SELECT departure_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) - julianday((SELECT arrival_on FROM group_reservations g WHERE g.group_id = reservation_rooms.group_id)) AS INTEGER) * 20 + 50) / 100 AS INTEGER)
           END
    """)
  end

  defp backfill_payment_accounting do
    execute("""
    INSERT INTO cash_payment_accountings
      (payment_operation_id, operation_record_id, group_id, recorded_cents, held_cents,
       refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents,
       charged_back_cents, inserted_at, updated_at)
    SELECT r.operation_id, r.id, json_extract(r.result, '$.group_id'),
           json_extract(r.result, '$.amount_cents'),
           CASE WHEN g.status = 'active' THEN json_extract(r.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.status <> 'active' AND g.cash_refunded_cents > 0 THEN json_extract(r.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.status <> 'active' AND g.cash_retained_cents > 0 THEN json_extract(r.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.status <> 'active' AND g.cash_converted_to_credit_cents > 0 THEN json_extract(r.result, '$.amount_cents') ELSE 0 END,
           0, 0, r.inserted_at, r.updated_at
      FROM partner_operation_records r
      JOIN group_reservations g ON g.group_id = json_extract(r.result, '$.group_id')
     WHERE r.operation_type = 'record_cash_payment'
       AND json_extract(r.result, '$.status') = 'applied'
    """)
  end

  defp backfill_active_cash_allocations do
    # Intersect cumulative funding blocks with cumulative room deposit capacity. The first block is
    # deliberately unattributed and therefore senior to every durable payment.
    execute("""
    WITH durable AS (
      SELECT p.group_id, COALESCE(SUM(p.recorded_cents), 0) AS amount
        FROM cash_payment_accountings p GROUP BY p.group_id
    ), blocks AS (
      SELECT g.group_id, NULL AS payment_id, -1 AS sequence,
             MAX(g.cash_paid_cents - COALESCE(d.amount, 0), 0) AS amount
        FROM group_reservations g LEFT JOIN durable d ON d.group_id = g.group_id
       WHERE g.status = 'active'
      UNION ALL
      SELECT p.group_id, p.id, r.id, p.held_cents
        FROM cash_payment_accountings p JOIN partner_operation_records r ON r.id = p.operation_record_id
    ), funding AS (
      SELECT *, COALESCE(SUM(amount) OVER (PARTITION BY group_id ORDER BY sequence ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at
        FROM blocks WHERE amount > 0
    ), room_ranges AS (
      SELECT room.*, COALESCE(SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at
        FROM reservation_rooms room WHERE status = 'active'
    )
    INSERT INTO room_cash_allocations
      (room_id, payment_accounting_id, amount_cents, inserted_at, updated_at)
    SELECT room.id, funding.payment_id,
           MIN(funding.starts_at + funding.amount, room.starts_at + room.deposit_due_cents) - MAX(funding.starts_at, room.starts_at),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM funding JOIN room_ranges room ON room.group_id = funding.group_id
     WHERE MIN(funding.starts_at + funding.amount, room.starts_at + room.deposit_due_cents) > MAX(funding.starts_at, room.starts_at)
    """)

    execute("""
    UPDATE reservation_rooms
       SET cash_paid_cents = COALESCE((SELECT SUM(a.amount_cents) FROM room_cash_allocations a WHERE a.room_id = reservation_rooms.id), 0)
    """)
  end

  defp backfill_credit_entitlements do
    execute("""
    WITH converted_groups AS (
      SELECT g.group_id, g.cash_converted_to_credit_cents,
             COALESCE(SUM(p.converted_to_credit_cents), 0) AS durable_principal
        FROM group_reservations g
        LEFT JOIN cash_payment_accountings p ON p.group_id = g.group_id
       WHERE g.cash_converted_to_credit_cents > 0
       GROUP BY g.group_id
    ), payment_ranges AS (
      SELECT p.id AS payment_id, p.group_id, p.converted_to_credit_cents AS principal,
             (g.cash_converted_to_credit_cents - g.durable_principal) +
             COALESCE(SUM(p.converted_to_credit_cents) OVER (
               PARTITION BY p.group_id ORDER BY p.operation_record_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding
        FROM cash_payment_accountings p
        JOIN converted_groups g ON g.group_id = p.group_id
       WHERE p.converted_to_credit_cents > 0
    ), cancellation_lots AS (
      SELECT lot.id AS lot_id, json_extract(operation.result, '$.group_id') AS group_id
        FROM hotel_credit_lots lot
        JOIN partner_operation_records operation
          ON operation.operation_id = lot.source_operation_id
       WHERE operation.operation_type = 'cancel_group'
         AND json_extract(operation.result, '$.status') = 'applied'
    )
    INSERT INTO credit_lot_entitlements
      (lot_id, payment_accounting_id, principal_cents, entitlement_cents, inserted_at, updated_at)
    SELECT lot.lot_id, payment.payment_id, payment.principal,
           (payment.preceding + payment.principal) + CAST(((payment.preceding + payment.principal) * 10 + 50) / 100 AS INTEGER) -
           (payment.preceding + CAST((payment.preceding * 10 + 50) / 100 AS INTEGER)),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM cancellation_lots lot
      JOIN payment_ranges payment ON payment.group_id = lot.group_id
    """)
  end

  defp backfill_active_credit_allocations do
    # Old credit allocations retain their lot-consumption order. Split that stream across the room
    # capacity left after the senior cash stream, then replace each old aggregate row.
    execute("""
    CREATE TEMP TABLE migrated_credit_allocations AS
    WITH credit AS (
      SELECT a.*, COALESCE(SUM(a.amount_cents) OVER (PARTITION BY a.group_id ORDER BY a.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at
        FROM hotel_credit_allocations a
    ), rooms AS (
      SELECT room.*,
             COALESCE(SUM(deposit_due_cents - cash_paid_cents) OVER (PARTITION BY group_id ORDER BY position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at
        FROM reservation_rooms room WHERE status = 'active'
    )
    SELECT credit.lot_id, credit.group_id, rooms.id AS room_id,
           MIN(credit.starts_at + credit.amount_cents, rooms.starts_at + rooms.deposit_due_cents - rooms.cash_paid_cents) - MAX(credit.starts_at, rooms.starts_at) AS amount_cents,
           credit.inserted_at, credit.updated_at
      FROM credit JOIN rooms ON rooms.group_id = credit.group_id
     WHERE MIN(credit.starts_at + credit.amount_cents, rooms.starts_at + rooms.deposit_due_cents - rooms.cash_paid_cents) > MAX(credit.starts_at, rooms.starts_at)
    """)

    execute("DELETE FROM hotel_credit_allocations")

    execute("""
    INSERT INTO hotel_credit_allocations (lot_id, group_id, room_id, amount_cents, inserted_at, updated_at)
    SELECT lot_id, group_id, room_id, amount_cents, inserted_at, updated_at FROM migrated_credit_allocations
    """)

    execute("DROP TABLE migrated_credit_allocations")

    execute("""
    UPDATE reservation_rooms
       SET credit_paid_cents = COALESCE((SELECT SUM(a.amount_cents) FROM hotel_credit_allocations a WHERE a.room_id = reservation_rooms.id), 0)
    """)
  end

  defp clear_cancelled_group_totals do
    execute("""
    UPDATE group_reservations
       SET lodging_total_cents = 0,
           deposit_due_cents = 0,
           deposit_paid_cents = 0,
           cash_paid_cents = 0,
           credit_paid_cents = 0
     WHERE status = 'cancelled'
    """)
  end
end
