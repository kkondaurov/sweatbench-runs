defmodule GroupStay.Repo.Migrations.AddRoomAndPaymentAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:funding_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :funding_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:funding_allocations, [:room_id])
    create index(:funding_allocations, [:funding_operation_id])
    create index(:funding_allocations, [:credit_lot_id])

    create table(:payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_dispositions, [:payment_operation_id])
    create index(:payment_dispositions, [:group_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :amount_cents, :integer, null: false
      add :clawed_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_entitlements, [:credit_lot_id, :payment_operation_id])

    flush()

    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * (
      SELECT CAST(julianday(g.departure_on) - julianday(g.arrival_on) AS INTEGER)
      FROM groups g WHERE g.id = rooms.group_id
    ),
    deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups g WHERE g.id = rooms.group_id) = 'flexible'
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
      WHEN (SELECT status FROM groups g WHERE g.id = rooms.group_id) = 'cancelled'
      THEN 'cancelled' ELSE 'active' END
    """)

    # Existing balances are the unattributed senior block. Existing durable payment
    # records are made reconcilable, while later operations use fully attributed rows.
    execute("""
    INSERT INTO payment_dispositions
      (payment_operation_id, group_id, recorded_cents, inserted_at, updated_at)
    SELECT o.operation_id, g.id, CAST(json_extract(o.result, '$.amount_cents') AS INTEGER),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM operation_records o
    JOIN groups g ON g.group_id = json_extract(o.result, '$.group_id')
    WHERE o.operation_type = 'record_cash_payment'
      AND json_extract(o.result, '$.status') = 'applied'
    """)

    execute("""
    WITH durable_cash AS (
      SELECT g.id AS group_id,
        COALESCE(SUM(CAST(json_extract(o.result, '$.amount_cents') AS INTEGER)), 0) AS amount_cents
      FROM groups g
      LEFT JOIN operation_records o
        ON o.operation_type = 'record_cash_payment'
       AND json_extract(o.result, '$.status') = 'applied'
       AND json_extract(o.result, '$.group_id') = g.group_id
      GROUP BY g.id
    ), durable_credit AS (
      SELECT g.id AS group_id,
        COALESCE(SUM(CAST(json_extract(o.result, '$.amount_cents') AS INTEGER)), 0) AS amount_cents
      FROM groups g
      LEFT JOIN operation_records o
        ON o.operation_type = 'apply_hotel_credit'
       AND json_extract(o.result, '$.status') = 'applied'
       AND json_extract(o.result, '$.group_id') = g.group_id
      GROUP BY g.id
    ), cash_segments AS (
      SELECT g.id AS group_id, 0 AS sequence, 0 AS sub_sequence,
        'cash' AS kind, NULL AS funding_operation_id, NULL AS credit_lot_id,
        MAX(0, g.cash_paid_cents - d.amount_cents) AS amount_cents
      FROM groups g JOIN durable_cash d ON d.group_id = g.id
      WHERE g.status = 'active'
      UNION ALL
      SELECT g.id, o.id, 0, 'cash', o.operation_id, NULL,
        CAST(json_extract(o.result, '$.amount_cents') AS INTEGER)
      FROM operation_records o
      JOIN groups g ON g.group_id = json_extract(o.result, '$.group_id')
      WHERE g.status = 'active'
        AND o.operation_type = 'record_cash_payment'
        AND json_extract(o.result, '$.status') = 'applied'
    ), credit_blocks AS (
      SELECT g.id AS group_id, 0 AS sequence, NULL AS funding_operation_id,
        MAX(0, g.credit_paid_cents - d.amount_cents) AS amount_cents
      FROM groups g JOIN durable_credit d ON d.group_id = g.id
      WHERE g.status = 'active'
      UNION ALL
      SELECT g.id, o.id, o.operation_id,
        CAST(json_extract(o.result, '$.amount_cents') AS INTEGER)
      FROM operation_records o
      JOIN groups g ON g.group_id = json_extract(o.result, '$.group_id')
      WHERE g.status = 'active'
        AND o.operation_type = 'apply_hotel_credit'
        AND json_extract(o.result, '$.status') = 'applied'
    ), credit_bounds AS (
      SELECT group_id, sequence, funding_operation_id, amount_cents,
        COALESCE(SUM(amount_cents) OVER (
          PARTITION BY group_id ORDER BY sequence
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) AS starts_at
      FROM credit_blocks WHERE amount_cents > 0
    ), lot_bounds AS (
      SELECT a.group_id, a.credit_lot_id, a.amount_cents,
        COALESCE(SUM(a.amount_cents) OVER (
          PARTITION BY a.group_id ORDER BY a.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) AS starts_at
      FROM credit_applications a
    ), credit_segments AS (
      SELECT f.group_id, f.sequence,
        MAX(f.starts_at, l.starts_at) AS sub_sequence,
        'credit' AS kind, f.funding_operation_id, l.credit_lot_id,
        MIN(f.starts_at + f.amount_cents, l.starts_at + l.amount_cents) -
          MAX(f.starts_at, l.starts_at) AS amount_cents
      FROM credit_bounds f JOIN lot_bounds l ON l.group_id = f.group_id
      WHERE MIN(f.starts_at + f.amount_cents, l.starts_at + l.amount_cents) >
            MAX(f.starts_at, l.starts_at)
    ), segments AS (
      SELECT * FROM cash_segments WHERE amount_cents > 0
      UNION ALL
      SELECT * FROM credit_segments
    ), funding_bounds AS (
      SELECT *, COALESCE(SUM(amount_cents) OVER (
        PARTITION BY group_id
        ORDER BY sequence, CASE kind WHEN 'cash' THEN 0 ELSE 1 END, sub_sequence
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0) AS starts_at
      FROM segments
    ), room_bounds AS (
      SELECT r.id AS room_id, r.group_id, r.deposit_due_cents,
        COALESCE(SUM(r.deposit_due_cents) OVER (
          PARTITION BY r.group_id ORDER BY r.position
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) AS starts_at
      FROM rooms r
    )
    INSERT INTO funding_allocations
      (room_id, kind, amount_cents, funding_operation_id, credit_lot_id,
       inserted_at, updated_at)
    SELECT r.room_id, f.kind,
      MIN(r.starts_at + r.deposit_due_cents, f.starts_at + f.amount_cents) -
        MAX(r.starts_at, f.starts_at),
      f.funding_operation_id, f.credit_lot_id,
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM room_bounds r JOIN funding_bounds f ON f.group_id = r.group_id
    WHERE MIN(r.starts_at + r.deposit_due_cents, f.starts_at + f.amount_cents) >
          MAX(r.starts_at, f.starts_at)
    """)

    execute("""
    UPDATE payment_dispositions
    SET refunded_cents = CASE WHEN (SELECT status FROM groups WHERE id = group_id) = 'cancelled'
      AND (SELECT refunded_cents FROM groups WHERE id = group_id) > 0 THEN recorded_cents ELSE 0 END,
        retained_cents = CASE WHEN (SELECT status FROM groups WHERE id = group_id) = 'cancelled'
      AND (SELECT retained_cents FROM groups WHERE id = group_id) > 0 THEN recorded_cents ELSE 0 END,
        converted_cents = CASE WHEN (SELECT status FROM groups WHERE id = group_id) = 'cancelled'
      AND (SELECT cash_converted_to_credit_cents FROM groups WHERE id = group_id) > 0
      THEN recorded_cents ELSE 0 END
    """)

    execute("""
    WITH converted_payments AS (
      SELECT l.id AS credit_lot_id, p.payment_operation_id, p.recorded_cents,
        MAX(0, g.cash_converted_to_credit_cents - SUM(p.recorded_cents) OVER (
          PARTITION BY l.id
        )) + COALESCE(SUM(p.recorded_cents) OVER (
          PARTITION BY l.id ORDER BY o.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) AS starts_at
      FROM credit_lots l
      JOIN operation_records cancellation ON cancellation.operation_id = l.source_operation_id
      JOIN groups g ON g.group_id = json_extract(cancellation.result, '$.group_id')
      JOIN payment_dispositions p ON p.group_id = g.id AND p.converted_cents > 0
      JOIN operation_records o ON o.operation_id = p.payment_operation_id
    )
    INSERT INTO credit_entitlements
      (credit_lot_id, payment_operation_id, amount_cents, clawed_back_cents,
       inserted_at, updated_at)
    SELECT credit_lot_id, payment_operation_id,
      recorded_cents +
        CAST(((starts_at + recorded_cents) * 10 + 50) / 100 AS INTEGER) -
        CAST((starts_at * 10 + 50) / 100 AS INTEGER),
      0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM converted_payments
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
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:payment_dispositions)
    drop table(:funding_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end
end
