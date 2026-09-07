defmodule GroupStay.Repo.Migrations.AddRoomAndPaymentAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :restrict)
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :room_id, references(:rooms, on_delete: :restrict), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_dispositions, [:payment_operation_id])
    create index(:payment_dispositions, [:group_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :credit_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()

    # Room prices were previously represented only by the group aggregate. They are deterministic
    # from the stored stay and rate, so the upgrade does not need partner input.
    execute("""
    UPDATE rooms
       SET lodging_total_cents = nightly_rate_cents *
           CAST(julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
                julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER)
    """)

    execute("""
    UPDATE rooms
       SET deposit_due_cents = CASE
         WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible'
           THEN CAST((lodging_total_cents * 20 + 50) / 100 AS INTEGER)
         ELSE lodging_total_cents
       END,
       status = CASE
         WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'cancelled'
           THEN 'cancelled' ELSE 'active' END
    """)

    # Establish reconciliation rows for payments covered by durable receipts. Existing cancelled
    # groups predate room settlement history, so their known aggregate settlement is apportioned in
    # payment commit order; active groups retain the full payment as held.
    execute("""
    INSERT INTO payment_dispositions
      (payment_operation_id, group_id, recorded_cents, held_cents, refunded_cents,
       retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents,
       inserted_at, updated_at)
    SELECT r.operation_id, g.id,
           CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER),
           CASE WHEN g.status = 'active' THEN CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) ELSE 0 END,
           CASE WHEN g.status = 'cancelled' AND g.refunded_cents > 0 THEN CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) ELSE 0 END,
           CASE WHEN g.status = 'cancelled' AND g.retained_cents > 0 THEN CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) ELSE 0 END,
           CASE WHEN g.status = 'cancelled' AND g.refunded_cents = 0 AND g.retained_cents = 0 THEN CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) ELSE 0 END,
           0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM operation_records r
      JOIN groups g ON g.group_id = json_extract(r.submitted_content, '$.group_id')
     WHERE r.operation_type = 'record_cash_payment'
       AND json_extract(r.result, '$.status') = 'applied'
    """)

    # Reconstruct each existing conversion lot's payment shares. The legacy principal is senior;
    # durable payments follow receipt order, and applying half-up rounding to running totals makes
    # the per-payment bonus shares telescope to the lot's exact issued value.
    execute("""
    WITH conversions AS (
      SELECT l.id lot_id, e.group_id, e.amount_cents principal
        FROM credit_lots l
        JOIN ledger_entries e
          ON e.operation_id = l.source_operation_id AND e.kind = 'credit_conversion'
    ), durable AS (
      SELECT c.lot_id, p.payment_operation_id, p.converted_to_credit_cents principal,
             r.id ordering
        FROM conversions c
        JOIN payment_dispositions p ON p.group_id = c.group_id
        JOIN operation_records r ON r.operation_id = p.payment_operation_id
       WHERE p.converted_to_credit_cents > 0
    ), legacy AS (
      SELECT c.lot_id, NULL payment_operation_id,
             MAX(c.principal - COALESCE(SUM(d.principal), 0), 0) principal, 0 ordering
        FROM conversions c LEFT JOIN durable d ON d.lot_id = c.lot_id
       GROUP BY c.lot_id
    ), contributions AS (
      SELECT * FROM legacy WHERE principal > 0 UNION ALL SELECT * FROM durable
    ), running AS (
      SELECT *,
             COALESCE(SUM(principal) OVER (PARTITION BY lot_id ORDER BY ordering ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) prior_principal
        FROM contributions
    )
    INSERT INTO credit_entitlements
      (credit_lot_id, payment_operation_id, principal_cents, credit_cents, revoked_cents,
       inserted_at, updated_at)
    SELECT lot_id, payment_operation_id, principal,
           principal + CAST(((prior_principal + principal) * 10 + 50) / 100 AS INTEGER)
             - CAST((prior_principal * 10 + 50) / 100 AS INTEGER),
           0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM running
    """)

    # Allocate active funding in the mandated order: legacy cash, legacy credit, and then durable
    # cash/credit operations in receipt commit order. Intersecting cumulative funding and room
    # ranges performs the fill without cent-by-cent loops.
    execute("""
    WITH durable_cash AS (
      SELECT p.group_id, 'cash' kind, p.payment_operation_id operation_id,
             p.recorded_cents amount, r.id + 2 ordering
        FROM payment_dispositions p
        JOIN operation_records r ON r.operation_id = p.payment_operation_id
        JOIN groups g ON g.id = p.group_id AND g.status = 'active'
    ), durable_credit AS (
      SELECT g.id group_id, 'credit' kind, r.operation_id,
             CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) amount,
             r.id + 2 ordering
        FROM operation_records r
        JOIN groups g ON g.group_id = json_extract(r.submitted_content, '$.group_id')
       WHERE g.status = 'active' AND r.operation_type = 'apply_hotel_credit'
         AND json_extract(r.result, '$.status') = 'applied'
    ), legacy_cash AS (
      SELECT g.id group_id, 'cash' kind, NULL operation_id,
             MAX(g.cash_paid_cents - COALESCE(SUM(d.amount), 0), 0) amount, 0 ordering
        FROM groups g LEFT JOIN durable_cash d ON d.group_id = g.id
       WHERE g.status = 'active' GROUP BY g.id
    ), legacy_credit AS (
      SELECT g.id group_id, 'credit' kind, NULL operation_id,
             MAX(g.credit_paid_cents - COALESCE(SUM(d.amount), 0), 0) amount, 1 ordering
        FROM groups g LEFT JOIN durable_credit d ON d.group_id = g.id
       WHERE g.status = 'active' GROUP BY g.id
    ), funding AS (
      SELECT * FROM legacy_cash WHERE amount > 0
      UNION ALL SELECT * FROM legacy_credit WHERE amount > 0
      UNION ALL SELECT * FROM durable_cash
      UNION ALL SELECT * FROM durable_credit
    ), funding_ranges AS (
      SELECT *, COALESCE(SUM(amount) OVER (PARTITION BY group_id ORDER BY ordering ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) start_at
        FROM funding
    ), room_ranges AS (
      SELECT rooms.*, COALESCE(SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) start_at
        FROM rooms WHERE status = 'active'
    )
    INSERT INTO cash_allocations
      (group_id, room_id, payment_operation_id, amount_cents, inserted_at, updated_at)
    SELECT f.group_id, rr.id, f.operation_id,
           MIN(f.start_at + f.amount, rr.start_at + rr.deposit_due_cents) - MAX(f.start_at, rr.start_at),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM funding_ranges f JOIN room_ranges rr ON rr.group_id = f.group_id
     WHERE f.kind = 'cash'
       AND MIN(f.start_at + f.amount, rr.start_at + rr.deposit_due_cents) > MAX(f.start_at, rr.start_at)
     ORDER BY f.ordering, rr.position
    """)

    # Existing credit allocation rows retain lot consumption order but not the application which
    # created them. Snapshot them, then intersect lot, funding-block, and room ranges to preserve
    # provenance even where one old row crosses a new room boundary.
    execute("""
    CREATE TEMPORARY TABLE credit_allocation_upgrade AS
      SELECT * FROM credit_allocations
    """)

    execute("""
    DELETE FROM credit_allocations
     WHERE group_id IN (SELECT id FROM groups WHERE status = 'active')
    """)

    execute("""
    WITH durable_cash AS (
      SELECT p.group_id, 'cash' kind, p.payment_operation_id operation_id,
             p.recorded_cents amount, r.id + 2 ordering
        FROM payment_dispositions p
        JOIN operation_records r ON r.operation_id = p.payment_operation_id
        JOIN groups g ON g.id = p.group_id AND g.status = 'active'
    ), durable_credit AS (
      SELECT g.id group_id, 'credit' kind, r.operation_id,
             CAST(json_extract(r.submitted_content, '$.amount_cents') AS INTEGER) amount,
             r.id + 2 ordering
        FROM operation_records r
        JOIN groups g ON g.group_id = json_extract(r.submitted_content, '$.group_id')
       WHERE g.status = 'active' AND r.operation_type = 'apply_hotel_credit'
         AND json_extract(r.result, '$.status') = 'applied'
    ), legacy_cash AS (
      SELECT g.id group_id, 'cash' kind, NULL operation_id,
             MAX(g.cash_paid_cents - COALESCE(SUM(d.amount), 0), 0) amount, 0 ordering
        FROM groups g LEFT JOIN durable_cash d ON d.group_id = g.id
       WHERE g.status = 'active' GROUP BY g.id
    ), legacy_credit AS (
      SELECT g.id group_id, 'credit' kind, NULL operation_id,
             MAX(g.credit_paid_cents - COALESCE(SUM(d.amount), 0), 0) amount, 1 ordering
        FROM groups g LEFT JOIN durable_credit d ON d.group_id = g.id
       WHERE g.status = 'active' GROUP BY g.id
    ), funding AS (
      SELECT * FROM legacy_cash WHERE amount > 0
      UNION ALL SELECT * FROM legacy_credit WHERE amount > 0
      UNION ALL SELECT * FROM durable_cash
      UNION ALL SELECT * FROM durable_credit
    ), funding_ranges AS (
      SELECT *,
             COALESCE(SUM(amount) OVER (PARTITION BY group_id ORDER BY ordering ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) start_at,
             COALESCE(SUM(CASE WHEN kind = 'credit' THEN amount ELSE 0 END) OVER (PARTITION BY group_id ORDER BY ordering ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) credit_start_at
        FROM funding
    ), room_ranges AS (
      SELECT rooms.*, COALESCE(SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) start_at
        FROM rooms WHERE status = 'active'
    ), lot_ranges AS (
      SELECT a.*,
             COALESCE(SUM(amount_cents) OVER (PARTITION BY group_id ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) start_at
        FROM credit_allocation_upgrade a
       WHERE group_id IN (SELECT id FROM groups WHERE status = 'active')
    ), pieces AS (
      SELECT f.group_id, rr.id room_id, lr.credit_lot_id, f.operation_id,
             MAX(f.credit_start_at + MAX(f.start_at, rr.start_at) - f.start_at, lr.start_at) piece_start,
             MIN(f.credit_start_at + MIN(f.start_at + f.amount, rr.start_at + rr.deposit_due_cents) - f.start_at,
                 lr.start_at + lr.amount_cents) piece_end
        FROM funding_ranges f
        JOIN room_ranges rr ON rr.group_id = f.group_id
        JOIN lot_ranges lr ON lr.group_id = f.group_id
       WHERE f.kind = 'credit'
    )
    INSERT INTO credit_allocations
      (group_id, room_id, credit_lot_id, operation_id, amount_cents, inserted_at, updated_at)
    SELECT group_id, room_id, credit_lot_id, operation_id, piece_end - piece_start,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM pieces WHERE piece_end > piece_start
    """)

    execute("DROP TABLE credit_allocation_upgrade")

    # Group totals now describe active rooms only. Historical ledger and payment dispositions keep
    # the settled amounts for cancelled groups; their live booking totals therefore become zero.
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
    drop table(:cash_allocations)

    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:credit_allocations) do
      remove :room_id
      remove :operation_id
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end
end
