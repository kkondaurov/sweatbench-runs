defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_applications) do
      add :group_room_id, references(:group_rooms, on_delete: :delete_all)
    end

    create index(:hotel_credit_applications, [:group_room_id])

    create table(:cash_room_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :group_room_id, references(:group_rooms, on_delete: :delete_all)
      add :payment_operation_id, :string
      add :credit_lot_id, references(:hotel_credit_lots, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_room_allocations, [:group_id, :disposition])
    create index(:cash_room_allocations, [:payment_operation_id, :disposition])
    create index(:cash_room_allocations, [:group_room_id, :disposition])
    create index(:cash_room_allocations, [:credit_lot_id])

    create table(:hotel_credit_lot_entitlements) do
      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_lot_entitlements, [:payment_operation_id])
    create index(:hotel_credit_lot_entitlements, [:hotel_credit_lot_id])

    # Persist the room amounts that were previously calculated only while opening a group.
    execute("""
    UPDATE group_rooms
    SET lodging_total_cents = nightly_rate_cents * CAST((
          SELECT julianday(g.departure_on) - julianday(g.arrival_on)
          FROM groups g WHERE g.id = group_rooms.group_id
        ) AS INTEGER),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups g WHERE g.id = group_rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST((
              SELECT julianday(g.departure_on) - julianday(g.arrival_on)
              FROM groups g WHERE g.id = group_rooms.group_id
            ) AS INTEGER)
          ELSE ((nightly_rate_cents * CAST((
              SELECT julianday(g.departure_on) - julianday(g.arrival_on)
              FROM groups g WHERE g.id = group_rooms.group_id
            ) AS INTEGER) * 20) + 50) / 100
        END,
        status = COALESCE((SELECT status FROM groups g WHERE g.id = group_rooms.group_id), 'active')
    """)

    # Replay every active group's funding stream into rooms.  The unattributed pre-durability block
    # comes first (cash, then its credit lots), followed by durable cash and credit in commit order.
    execute("""
    WITH durable_operations AS (
      SELECT p.id AS commit_order,
             p.operation_id,
             p.operation_type,
             json_extract(p.result, '$.group_id') AS group_external_id,
             CAST(json_extract(p.result, '$.amount_cents') AS INTEGER) AS amount_cents
      FROM partner_operations p
      WHERE p.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(p.result, '$.status') = 'applied'
    ), durable_totals AS (
      SELECT group_external_id,
             SUM(CASE WHEN operation_type = 'record_cash_payment' THEN amount_cents ELSE 0 END) AS cash_cents,
             SUM(CASE WHEN operation_type = 'apply_hotel_credit' THEN amount_cents ELSE 0 END) AS credit_cents
      FROM durable_operations
      GROUP BY group_external_id
    ), group_funding AS (
      SELECT g.id AS group_id,
             g.group_id AS group_external_id,
             MAX(g.cash_paid_cents - COALESCE(d.cash_cents, 0), 0) AS legacy_cash_cents,
             MAX(g.credit_paid_cents - COALESCE(d.credit_cents, 0), 0) AS legacy_credit_cents
      FROM groups g
      LEFT JOIN durable_totals d ON d.group_external_id = g.group_id
      WHERE g.status = 'active'
    ), application_bounds AS (
      SELECT a.id,
             a.group_id,
             a.hotel_credit_lot_id,
             a.amount_cents,
             a.inserted_at,
             a.updated_at,
             f.legacy_credit_cents,
             COALESCE(SUM(a.amount_cents) OVER (
               PARTITION BY a.group_id ORDER BY a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(a.amount_cents) OVER (
               PARTITION BY a.group_id ORDER BY a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM hotel_credit_applications a
      JOIN group_funding f ON f.group_id = a.group_id
      WHERE a.group_room_id IS NULL
    ), credit_operations AS (
      SELECT d.commit_order,
             d.operation_id,
             f.group_id,
             f.legacy_credit_cents + COALESCE(SUM(d.amount_cents) OVER (
               PARTITION BY f.group_id ORDER BY d.commit_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             f.legacy_credit_cents + SUM(d.amount_cents) OVER (
               PARTITION BY f.group_id ORDER BY d.commit_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM durable_operations d
      JOIN group_funding f ON f.group_external_id = d.group_external_id
      WHERE d.operation_type = 'apply_hotel_credit'
    ), funding_sources AS (
      SELECT group_id, NULL AS payment_operation_id, NULL AS credit_lot_id,
             'cash' AS funding_kind, 0 AS source_order, 0 AS source_suborder,
             legacy_cash_cents AS amount_cents
      FROM group_funding

      UNION ALL

      SELECT a.group_id, NULL, a.hotel_credit_lot_id,
             'credit', 0, a.id,
             MIN(a.upper_bound, a.legacy_credit_cents) - a.lower_bound
      FROM application_bounds a
      WHERE MIN(a.upper_bound, a.legacy_credit_cents) > a.lower_bound

      UNION ALL

      SELECT f.group_id, d.operation_id, NULL,
             'cash', d.commit_order, 0, d.amount_cents
      FROM durable_operations d
      JOIN group_funding f ON f.group_external_id = d.group_external_id
      WHERE d.operation_type = 'record_cash_payment'

      UNION ALL

      SELECT a.group_id, NULL, a.hotel_credit_lot_id,
             'credit', d.commit_order, a.id,
             MIN(a.upper_bound, d.upper_bound) - MAX(a.lower_bound, d.lower_bound)
      FROM application_bounds a
      JOIN credit_operations d ON d.group_id = a.group_id
      WHERE MIN(a.upper_bound, d.upper_bound) > MAX(a.lower_bound, d.lower_bound)
    ), source_bounds AS (
      SELECT s.*,
             COALESCE(SUM(s.amount_cents) OVER (
               PARTITION BY s.group_id
               ORDER BY s.source_order, s.source_suborder
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(s.amount_cents) OVER (
               PARTITION BY s.group_id
               ORDER BY s.source_order, s.source_suborder
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM funding_sources s
      WHERE s.amount_cents > 0
    ), room_bounds AS (
      SELECT r.id AS room_id,
             r.group_id,
             COALESCE(SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM group_rooms r
    )
    INSERT INTO cash_room_allocations
      (group_id, group_room_id, payment_operation_id, credit_lot_id, amount_cents, disposition, inserted_at, updated_at)
    SELECT s.group_id, r.room_id, s.payment_operation_id, NULL,
           MIN(s.upper_bound, r.upper_bound) - MAX(s.lower_bound, r.lower_bound),
           'held', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM source_bounds s
    JOIN room_bounds r ON r.group_id = s.group_id
    WHERE s.funding_kind = 'cash'
      AND MIN(s.upper_bound, r.upper_bound) > MAX(s.lower_bound, r.lower_bound)
    """)

    execute("""
    WITH durable_operations AS (
      SELECT p.id AS commit_order,
             p.operation_type,
             json_extract(p.result, '$.group_id') AS group_external_id,
             CAST(json_extract(p.result, '$.amount_cents') AS INTEGER) AS amount_cents
      FROM partner_operations p
      WHERE p.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(p.result, '$.status') = 'applied'
    ), durable_totals AS (
      SELECT group_external_id,
             SUM(CASE WHEN operation_type = 'record_cash_payment' THEN amount_cents ELSE 0 END) AS cash_cents,
             SUM(CASE WHEN operation_type = 'apply_hotel_credit' THEN amount_cents ELSE 0 END) AS credit_cents
      FROM durable_operations
      GROUP BY group_external_id
    ), group_funding AS (
      SELECT g.id AS group_id,
             g.group_id AS group_external_id,
             MAX(g.cash_paid_cents - COALESCE(d.cash_cents, 0), 0) AS legacy_cash_cents,
             MAX(g.credit_paid_cents - COALESCE(d.credit_cents, 0), 0) AS legacy_credit_cents
      FROM groups g
      LEFT JOIN durable_totals d ON d.group_external_id = g.group_id
      WHERE g.status = 'active'
    ), application_bounds AS (
      SELECT a.id,
             a.group_id,
             a.hotel_credit_lot_id,
             a.amount_cents,
             a.inserted_at,
             a.updated_at,
             f.legacy_cash_cents,
             f.legacy_credit_cents,
             COALESCE(SUM(a.amount_cents) OVER (
               PARTITION BY a.group_id ORDER BY a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(a.amount_cents) OVER (
               PARTITION BY a.group_id ORDER BY a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM hotel_credit_applications a
      JOIN group_funding f ON f.group_id = a.group_id
      WHERE a.group_room_id IS NULL
    ), durable_positions AS (
      SELECT d.*,
             f.group_id,
             f.legacy_cash_cents,
             f.legacy_credit_cents,
             COALESCE(SUM(d.amount_cents) OVER (
               PARTITION BY f.group_id ORDER BY d.commit_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS prior_durable_cents
      FROM durable_operations d
      JOIN group_funding f ON f.group_external_id = d.group_external_id
    ), credit_operations AS (
      SELECT d.commit_order,
             d.group_id,
             d.legacy_cash_cents,
             d.legacy_credit_cents,
             d.prior_durable_cents,
             d.legacy_credit_cents + COALESCE(SUM(d.amount_cents) OVER (
               PARTITION BY d.group_id ORDER BY d.commit_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             d.legacy_credit_cents + SUM(d.amount_cents) OVER (
               PARTITION BY d.group_id ORDER BY d.commit_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM durable_positions d
      WHERE d.operation_type = 'apply_hotel_credit'
    ), credit_sources AS (
      SELECT a.group_id, a.hotel_credit_lot_id,
             a.legacy_cash_cents + a.lower_bound AS lower_bound,
             a.legacy_cash_cents + MIN(a.upper_bound, a.legacy_credit_cents) AS upper_bound
      FROM application_bounds a
      WHERE MIN(a.upper_bound, a.legacy_credit_cents) > a.lower_bound

      UNION ALL

      SELECT a.group_id, a.hotel_credit_lot_id,
             d.legacy_cash_cents + d.legacy_credit_cents + d.prior_durable_cents +
               MAX(a.lower_bound, d.lower_bound) - d.lower_bound,
             d.legacy_cash_cents + d.legacy_credit_cents + d.prior_durable_cents +
               MIN(a.upper_bound, d.upper_bound) - d.lower_bound
      FROM application_bounds a
      JOIN credit_operations d ON d.group_id = a.group_id
      WHERE MIN(a.upper_bound, d.upper_bound) > MAX(a.lower_bound, d.lower_bound)
    ), room_bounds AS (
      SELECT r.id AS room_id,
             r.group_id,
             COALESCE(SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM group_rooms r
    )
    INSERT INTO hotel_credit_applications
      (group_id, hotel_credit_lot_id, amount_cents, group_room_id, inserted_at, updated_at)
    SELECT s.group_id, s.hotel_credit_lot_id,
           MIN(s.upper_bound, r.upper_bound) - MAX(s.lower_bound, r.lower_bound),
           r.room_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM credit_sources s
    JOIN room_bounds r ON r.group_id = s.group_id
    WHERE MIN(s.upper_bound, r.upper_bound) > MAX(s.lower_bound, r.lower_bound)
    """)

    execute("DELETE FROM hotel_credit_applications WHERE group_room_id IS NULL")

    execute("""
    UPDATE group_rooms
    SET cash_paid_cents = COALESCE((
          SELECT SUM(a.amount_cents)
          FROM cash_room_allocations a
          WHERE a.group_room_id = group_rooms.id AND a.disposition = 'held'
        ), 0),
        credit_paid_cents = COALESCE((
          SELECT SUM(a.amount_cents)
          FROM hotel_credit_applications a
          WHERE a.group_room_id = group_rooms.id
        ), 0)
    """)

    # Do the same reconstruction for historical settlements.  These have no active room balance,
    # but retaining the payment identity keeps their ledger and payment statements reconcilable.
    execute("""
    WITH durable_cash AS (
      SELECT p.id AS commit_order,
             p.operation_id AS payment_operation_id,
             json_extract(p.result, '$.group_id') AS group_external_id,
             CAST(json_extract(p.result, '$.amount_cents') AS INTEGER) AS amount_cents
      FROM partner_operations p
      WHERE p.operation_type = 'record_cash_payment'
        AND json_extract(p.result, '$.status') = 'applied'
    ), settlements AS (
      SELECT g.*,
             refunded_cents + retained_cents + cash_converted_to_credit_cents AS total_cents,
             CASE
               WHEN refunded_cents > 0 THEN 'refunded'
               WHEN retained_cents > 0 THEN 'retained'
               WHEN cash_converted_to_credit_cents > 0 THEN 'converted'
             END AS disposition
      FROM groups g
      WHERE g.status = 'cancelled'
    ), cash_sources AS (
      SELECT s.id AS group_id,
             NULL AS payment_operation_id,
             0 AS commit_order,
             MAX(s.total_cents - COALESCE(SUM(d.amount_cents), 0), 0) AS amount_cents,
             s.disposition
      FROM settlements s
      LEFT JOIN durable_cash d ON d.group_external_id = s.group_id
      WHERE s.total_cents > 0
      GROUP BY s.id

      UNION ALL

      SELECT s.id, d.payment_operation_id, d.commit_order, d.amount_cents, s.disposition
      FROM settlements s
      JOIN durable_cash d ON d.group_external_id = s.group_id
      WHERE s.total_cents > 0
    )
    INSERT INTO cash_room_allocations
      (group_id, group_room_id, payment_operation_id, credit_lot_id, amount_cents, disposition, inserted_at, updated_at)
    SELECT s.group_id, NULL, s.payment_operation_id,
           CASE WHEN s.disposition = 'converted' THEN (
             SELECT l.id
             FROM hotel_credit_lots l
             JOIN partner_operations c ON c.operation_id = l.source_operation_id
             JOIN groups g ON g.id = s.group_id
             WHERE c.operation_type = 'cancel_group'
               AND json_extract(c.result, '$.group_id') = g.group_id
             ORDER BY l.id
             LIMIT 1
           ) END,
           s.amount_cents, s.disposition, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM cash_sources s
    WHERE s.amount_cents > 0
    """)

    execute("""
    WITH entitlement_bounds AS (
      SELECT a.credit_lot_id,
             a.payment_operation_id,
             a.amount_cents,
             COALESCE(SUM(a.amount_cents) OVER (
               PARTITION BY a.credit_lot_id
               ORDER BY CASE WHEN a.payment_operation_id IS NULL THEN 0 ELSE 1 END, p.id, a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS lower_bound,
             SUM(a.amount_cents) OVER (
               PARTITION BY a.credit_lot_id
               ORDER BY CASE WHEN a.payment_operation_id IS NULL THEN 0 ELSE 1 END, p.id, a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS upper_bound
      FROM cash_room_allocations a
      LEFT JOIN partner_operations p ON p.operation_id = a.payment_operation_id
      WHERE a.disposition = 'converted' AND a.credit_lot_id IS NOT NULL
    )
    INSERT INTO hotel_credit_lot_entitlements
      (hotel_credit_lot_id, payment_operation_id, amount_cents, inserted_at, updated_at)
    SELECT credit_lot_id, payment_operation_id,
           upper_bound + ((upper_bound * 10 + 50) / 100) -
             lower_bound - ((lower_bound * 10 + 50) / 100),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM entitlement_bounds
    """)

    execute("""
    UPDATE groups
    SET lodging_total_cents = COALESCE((
          SELECT SUM(r.lodging_total_cents) FROM group_rooms r
          WHERE r.group_id = groups.id AND r.status = 'active'
        ), 0),
        deposit_due_cents = COALESCE((
          SELECT SUM(r.deposit_due_cents) FROM group_rooms r
          WHERE r.group_id = groups.id AND r.status = 'active'
        ), 0),
        cash_paid_cents = COALESCE((
          SELECT SUM(r.cash_paid_cents) FROM group_rooms r
          WHERE r.group_id = groups.id AND r.status = 'active'
        ), 0),
        credit_paid_cents = COALESCE((
          SELECT SUM(r.credit_paid_cents) FROM group_rooms r
          WHERE r.group_id = groups.id AND r.status = 'active'
        ), 0),
        deposit_paid_cents = COALESCE((
          SELECT SUM(r.cash_paid_cents + r.credit_paid_cents) FROM group_rooms r
          WHERE r.group_id = groups.id AND r.status = 'active'
        ), 0)
    """)
  end

  def down do
    drop table(:hotel_credit_lot_entitlements)
    drop table(:cash_room_allocations)
    drop index(:hotel_credit_applications, [:group_room_id])

    alter table(:hotel_credit_applications) do
      remove :group_room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
