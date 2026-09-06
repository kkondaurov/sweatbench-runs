defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:funding_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :funding_type, :string, null: false
      add :funding_operation_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false, default: "held"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:funding_allocations, [:group_id, :room_id])
    create index(:funding_allocations, [:payment_operation_id])
    create index(:funding_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()
    backfill_rooms_and_cash()
    backfill_credit()
    backfill_entitlements()
    refresh_room_funding_totals()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:funding_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  defp backfill_rooms_and_cash do
    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * (
          SELECT CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
          FROM groups g WHERE g.id = rooms.group_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE id = rooms.group_id) = 'flexible'
            THEN CAST((nightly_rate_cents * (
              SELECT CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
              FROM groups g WHERE g.id = rooms.group_id
            ) * 20 + 50) / 100 AS INTEGER)
          ELSE nightly_rate_cents * (
            SELECT CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
            FROM groups g WHERE g.id = rooms.group_id
          )
        END,
        status = CASE
          WHEN (SELECT status FROM groups WHERE id = rooms.group_id) = 'cancelled' THEN 'cancelled'
          ELSE 'active'
        END
    """)

    execute("""
    INSERT INTO funding_allocations
      (group_id, room_id, funding_type, funding_operation_id, payment_operation_id,
       amount_cents, disposition, inserted_at, updated_at)
    WITH durable_funding AS (
      SELECT p.id AS operation_order, p.operation_type,
             json_extract(p.result, '$.group_id') AS group_key,
             p.operation_id,
             CAST(json_extract(p.result, '$.amount_cents') AS INTEGER) AS amount_cents
      FROM partner_operations p
      WHERE p.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(p.result, '$.status') = 'applied'
    ),
    legacy AS (
      SELECT g.id AS group_id,
             g.cash_paid_cents - COALESCE((SELECT SUM(d.amount_cents) FROM durable_funding d
               WHERE d.group_key = g.group_id AND d.operation_type = 'record_cash_payment'), 0) AS cash_cents,
             COALESCE((SELECT SUM(ca.amount_cents) FROM credit_allocations ca
               WHERE ca.group_id = g.id), 0) - COALESCE((SELECT SUM(d.amount_cents)
               FROM durable_funding d WHERE d.group_key = g.group_id
                 AND d.operation_type = 'apply_hotel_credit'), 0) AS credit_cents
      FROM groups g
    ),
    sources AS (
      SELECT l.group_id, NULL AS payment_operation_id, l.cash_cents AS amount_cents,
             0 AS starts_at, l.cash_cents AS ends_at
      FROM legacy l
      UNION ALL
      SELECT g.id, d.operation_id, d.amount_cents,
             l.cash_cents + l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents)
               FROM durable_funding previous WHERE previous.group_key = d.group_key
                 AND previous.operation_order < d.operation_order), 0),
             l.cash_cents + l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents)
               FROM durable_funding previous WHERE previous.group_key = d.group_key
                 AND previous.operation_order < d.operation_order), 0) + d.amount_cents
      FROM durable_funding d
      JOIN groups g ON g.group_id = d.group_key
      JOIN legacy l ON l.group_id = g.id
      WHERE d.operation_type = 'record_cash_payment'
    ),
    room_intervals AS (
      SELECT r.*,
             COALESCE(SUM(deposit_due_cents) OVER (
               PARTITION BY group_id ORDER BY position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS starts_at,
             SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position) AS ends_at
      FROM rooms r
    )
    SELECT s.group_id, r.id, 'cash', s.payment_operation_id, s.payment_operation_id,
           MIN(s.ends_at, r.ends_at) - MAX(s.starts_at, r.starts_at),
           CASE
             WHEN g.status = 'active' THEN 'held'
             WHEN g.cash_refunded_cents > 0 THEN 'refunded'
             WHEN g.cash_retained_cents > 0 THEN 'retained'
             ELSE 'converted'
           END,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM sources s
    JOIN room_intervals r ON r.group_id = s.group_id
      AND MIN(s.ends_at, r.ends_at) > MAX(s.starts_at, r.starts_at)
    JOIN groups g ON g.id = s.group_id
    ORDER BY s.group_id, s.starts_at, r.position
    """)
  end

  defp backfill_credit do
    execute("""
    INSERT INTO funding_allocations
      (group_id, room_id, credit_lot_id, funding_type, funding_operation_id,
       amount_cents, disposition, inserted_at, updated_at)
    WITH durable_funding AS (
      SELECT p.id AS operation_order, p.operation_type,
             json_extract(p.result, '$.group_id') AS group_key,
             p.operation_id,
             CAST(json_extract(p.result, '$.amount_cents') AS INTEGER) AS amount_cents
      FROM partner_operations p
      WHERE p.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(p.result, '$.status') = 'applied'
    ),
    legacy AS (
      SELECT g.id AS group_id,
             g.cash_paid_cents - COALESCE((SELECT SUM(d.amount_cents) FROM durable_funding d
               WHERE d.group_key = g.group_id AND d.operation_type = 'record_cash_payment'), 0) AS cash_cents,
             COALESCE((SELECT SUM(ca.amount_cents) FROM credit_allocations ca
               WHERE ca.group_id = g.id), 0) - COALESCE((SELECT SUM(d.amount_cents)
               FROM durable_funding d WHERE d.group_key = g.group_id
                 AND d.operation_type = 'apply_hotel_credit'), 0) AS credit_cents
      FROM groups g
    ),
    operation_sources AS (
      SELECT l.group_id, NULL AS operation_id, l.credit_cents AS amount_cents,
             0 AS credit_starts_at, l.credit_cents AS credit_ends_at,
             l.cash_cents AS global_starts_at, l.cash_cents + l.credit_cents AS global_ends_at
      FROM legacy l
      UNION ALL
      SELECT g.id, d.operation_id, d.amount_cents,
             l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents) FROM durable_funding previous
               WHERE previous.group_key = d.group_key AND previous.operation_type = 'apply_hotel_credit'
                 AND previous.operation_order < d.operation_order), 0),
             l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents) FROM durable_funding previous
               WHERE previous.group_key = d.group_key AND previous.operation_type = 'apply_hotel_credit'
                 AND previous.operation_order < d.operation_order), 0) + d.amount_cents,
             l.cash_cents + l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents)
               FROM durable_funding previous WHERE previous.group_key = d.group_key
                 AND previous.operation_order < d.operation_order), 0),
             l.cash_cents + l.credit_cents + COALESCE((SELECT SUM(previous.amount_cents)
               FROM durable_funding previous WHERE previous.group_key = d.group_key
                 AND previous.operation_order < d.operation_order), 0) + d.amount_cents
      FROM durable_funding d
      JOIN groups g ON g.group_id = d.group_key
      JOIN legacy l ON l.group_id = g.id
      WHERE d.operation_type = 'apply_hotel_credit'
    ),
    lot_intervals AS (
      SELECT ca.*,
             COALESCE(SUM(amount_cents) OVER (PARTITION BY group_id ORDER BY id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at,
             SUM(amount_cents) OVER (PARTITION BY group_id ORDER BY id) AS ends_at
      FROM credit_allocations ca
    ),
    operation_lot_chunks AS (
      SELECT os.group_id, os.operation_id, li.credit_lot_id,
             os.global_starts_at + MAX(os.credit_starts_at, li.starts_at) - os.credit_starts_at AS starts_at,
             os.global_starts_at + MIN(os.credit_ends_at, li.ends_at) - os.credit_starts_at AS ends_at
      FROM operation_sources os
      JOIN lot_intervals li ON li.group_id = os.group_id
      WHERE os.amount_cents > 0
        AND MIN(os.credit_ends_at, li.ends_at) > MAX(os.credit_starts_at, li.starts_at)
    ),
    room_intervals AS (
      SELECT r.*,
             COALESCE(SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS starts_at,
             SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position) AS ends_at
      FROM rooms r
    )
    SELECT chunk.group_id, ri.id, chunk.credit_lot_id, 'credit', chunk.operation_id,
           MIN(chunk.ends_at, ri.ends_at) - MAX(chunk.starts_at, ri.starts_at),
           'held', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM operation_lot_chunks chunk
    JOIN room_intervals ri ON ri.group_id = chunk.group_id
    WHERE MIN(chunk.ends_at, ri.ends_at) > MAX(chunk.starts_at, ri.starts_at)
    ORDER BY chunk.group_id, chunk.starts_at, ri.position
    """)
  end

  defp backfill_entitlements do
    execute("""
    INSERT INTO credit_entitlements
      (credit_lot_id, payment_operation_id, principal_cents, entitlement_cents,
       revoked_cents, inserted_at, updated_at)
    WITH contributions AS (
      SELECT lot.id AS lot_id, fa.payment_operation_id, SUM(fa.amount_cents) AS principal_cents,
             MIN(fa.id) AS funding_order
      FROM credit_lots lot
      JOIN partner_operations cancellation ON cancellation.operation_id = lot.source_operation_id
      JOIN groups g ON g.group_id = json_extract(cancellation.result, '$.group_id')
      JOIN funding_allocations fa ON fa.group_id = g.id AND fa.disposition = 'converted'
      GROUP BY lot.id, fa.payment_operation_id
    ),
    running AS (
      SELECT c.*,
             SUM(principal_cents) OVER (PARTITION BY lot_id ORDER BY funding_order) AS through_cents,
             COALESCE(SUM(principal_cents) OVER (PARTITION BY lot_id ORDER BY funding_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS preceding_cents
      FROM contributions c
    )
    SELECT lot_id, payment_operation_id, principal_cents,
           principal_cents + CAST((through_cents * 10 + 50) / 100 AS INTEGER) -
             CAST((preceding_cents * 10 + 50) / 100 AS INTEGER),
           0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM running
    """)
  end

  defp refresh_room_funding_totals do
    execute("""
    UPDATE rooms
    SET cash_paid_cents = COALESCE((SELECT SUM(amount_cents) FROM funding_allocations fa
      WHERE fa.room_id = rooms.id AND fa.funding_type = 'cash' AND fa.disposition = 'held'), 0),
        credit_paid_cents = COALESCE((SELECT SUM(amount_cents) FROM funding_allocations fa
      WHERE fa.room_id = rooms.id AND fa.funding_type = 'credit' AND fa.disposition = 'held'), 0)
    """)
  end
end
