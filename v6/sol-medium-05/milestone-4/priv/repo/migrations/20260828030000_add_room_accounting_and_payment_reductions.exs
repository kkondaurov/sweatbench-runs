defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments) do
      add :operation_id, :string, null: false
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
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

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:cash_payment_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict), null: false
      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:cash_payment_id])
    create index(:credit_entitlements, [:credit_lot_id])

    execute("""
    UPDATE rooms
    SET status = (SELECT groups.status FROM groups WHERE groups.group_id = rooms.group_id),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'flexible'
          THEN CAST((nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
          ) * 20 + 50) / 100 AS INTEGER)
          ELSE nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
          )
        END
    """)

    # Reconstruct applied durable cash payments. Older active funding in excess
    # of these records remains the unattributed senior block.
    execute("""
    INSERT INTO cash_payments
      (operation_id, group_id, recorded_cents, refunded_cents, retained_cents,
       converted_cents, reduced_cents, charged_back_cents, inserted_at, updated_at)
    SELECT po.operation_id,
      json_extract(po.payload, '$.group_id'),
      json_extract(po.payload, '$.amount_cents'),
      CASE WHEN g.status = 'cancelled' AND g.cash_refunded_cents > 0
        THEN json_extract(po.payload, '$.amount_cents') ELSE 0 END,
      CASE WHEN g.status = 'cancelled' AND g.cash_retained_cents > 0
        THEN json_extract(po.payload, '$.amount_cents') ELSE 0 END,
      CASE WHEN g.status = 'cancelled' AND g.cash_converted_to_credit_cents > 0
        THEN json_extract(po.payload, '$.amount_cents') ELSE 0 END,
      0, 0, po.inserted_at, po.updated_at
    FROM partner_operations po
    JOIN groups g ON g.group_id = json_extract(po.payload, '$.group_id')
    WHERE po.operation_type = 'record_cash_payment'
      AND json_extract(po.result, '$.status') = 'applied'
    ORDER BY po.id
    """)

    # Existing converted lots may also have durable source payments. Rebuild
    # each payment's telescoping 110% entitlement, with legacy principal as the
    # senior prefix. Request 02 only created one conversion lot per cancelled
    # group, identified by the cancellation operation stored as the lot source.
    execute("""
    INSERT INTO credit_entitlements
      (credit_lot_id, cash_payment_id, amount_cents, inserted_at, updated_at)
    SELECT ranked.credit_lot_id, ranked.cash_payment_id,
      CAST(((ranked.legacy_principal + ranked.cumulative_payment) * 110 + 50) / 100 AS INTEGER) -
      CAST(((ranked.legacy_principal + ranked.previous_payment) * 110 + 50) / 100 AS INTEGER),
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM (
      SELECT lot.id AS credit_lot_id, payment.id AS cash_payment_id,
        g.cash_converted_to_credit_cents - SUM(payment.recorded_cents) OVER (
          PARTITION BY lot.id
        ) AS legacy_principal,
        SUM(payment.recorded_cents) OVER (
          PARTITION BY lot.id ORDER BY payment.id
        ) AS cumulative_payment,
        SUM(payment.recorded_cents) OVER (
          PARTITION BY lot.id ORDER BY payment.id
        ) - payment.recorded_cents AS previous_payment
      FROM credit_lots lot
      JOIN partner_operations cancellation ON cancellation.operation_id = lot.source_operation_id
      JOIN groups g ON g.group_id = json_extract(cancellation.payload, '$.group_id')
      JOIN cash_payments payment ON payment.group_id = g.group_id AND payment.converted_cents > 0
    ) ranked
    """)

    # Build the exact funding sequence for every active group. The senior tier
    # is legacy cash followed by legacy credit in its old consumption order.
    # Durable cash and credit operations are then interleaved by audit-record
    # commit order. Credit operations are intersected with the old lot-level
    # allocation stream so restoration continues to target the original lots.
    execute("""
    CREATE TEMPORARY TABLE room_funding_segments (
      group_id TEXT NOT NULL,
      cash_payment_id INTEGER,
      credit_lot_id INTEGER,
      amount_cents INTEGER NOT NULL,
      tier INTEGER NOT NULL,
      operation_order INTEGER NOT NULL,
      suborder INTEGER NOT NULL
    )
    """)

    execute("""
    INSERT INTO room_funding_segments
    SELECT g.group_id, NULL, NULL,
      g.cash_paid_cents - COALESCE((
        SELECT SUM(p.recorded_cents) FROM cash_payments p WHERE p.group_id = g.group_id
      ), 0),
      0, 0, 0
    FROM groups g
    WHERE g.status = 'active' AND g.cash_paid_cents > COALESCE((
      SELECT SUM(p.recorded_cents) FROM cash_payments p WHERE p.group_id = g.group_id
    ), 0)
    """)

    execute("""
    INSERT INTO room_funding_segments
    SELECT ranked.group_id, NULL, ranked.credit_lot_id,
      MIN(ranked.cumulative_credit, ranked.legacy_credit) - ranked.previous_credit,
      1, ranked.allocation_id, 0
    FROM (
      SELECT a.id AS allocation_id, a.group_id, a.credit_lot_id,
        g.credit_paid_cents - COALESCE((
          SELECT SUM(json_extract(po.payload, '$.amount_cents'))
          FROM partner_operations po
          WHERE po.operation_type = 'apply_hotel_credit'
            AND json_extract(po.result, '$.status') = 'applied'
            AND json_extract(po.payload, '$.group_id') = a.group_id
        ), 0) AS legacy_credit,
        SUM(a.amount_cents) OVER (PARTITION BY a.group_id ORDER BY a.id) AS cumulative_credit,
        SUM(a.amount_cents) OVER (PARTITION BY a.group_id ORDER BY a.id) - a.amount_cents AS previous_credit
      FROM credit_allocations a
      JOIN groups g ON g.group_id = a.group_id AND g.status = 'active'
      WHERE a.room_id IS NULL
    ) ranked
    WHERE ranked.previous_credit < ranked.legacy_credit
    """)

    execute("""
    INSERT INTO room_funding_segments
    SELECT durable.group_id, durable.cash_payment_id, durable.credit_lot_id,
      durable.amount_cents, 2, durable.operation_order, durable.suborder
    FROM (
      SELECT p.group_id, p.id AS cash_payment_id, NULL AS credit_lot_id,
        p.recorded_cents AS amount_cents, po.id AS operation_order, 0 AS suborder
      FROM partner_operations po
      JOIN cash_payments p ON p.operation_id = po.operation_id
      JOIN groups g ON g.group_id = p.group_id AND g.status = 'active'

      UNION ALL

      SELECT intersections.group_id, NULL, intersections.credit_lot_id,
        MIN(intersections.operation_end, intersections.allocation_end) -
          MAX(intersections.operation_start, intersections.allocation_start),
        intersections.operation_order, intersections.allocation_id
      FROM (
        SELECT credit_ops.group_id, credit_ops.operation_order,
          credit_ops.operation_start, credit_ops.operation_end,
          allocations.allocation_id, allocations.credit_lot_id,
          allocations.cumulative_credit - credit_ops.legacy_credit AS allocation_end,
          allocations.previous_credit - credit_ops.legacy_credit AS allocation_start
        FROM (
          SELECT po.id AS operation_order,
            json_extract(po.payload, '$.group_id') AS group_id,
            g.credit_paid_cents - SUM(json_extract(po.payload, '$.amount_cents')) OVER (
              PARTITION BY json_extract(po.payload, '$.group_id')
            ) AS legacy_credit,
            SUM(json_extract(po.payload, '$.amount_cents')) OVER (
              PARTITION BY json_extract(po.payload, '$.group_id') ORDER BY po.id
            ) AS operation_end,
            SUM(json_extract(po.payload, '$.amount_cents')) OVER (
              PARTITION BY json_extract(po.payload, '$.group_id') ORDER BY po.id
            ) - json_extract(po.payload, '$.amount_cents') AS operation_start
          FROM partner_operations po
          JOIN groups g ON g.group_id = json_extract(po.payload, '$.group_id') AND g.status = 'active'
          WHERE po.operation_type = 'apply_hotel_credit'
            AND json_extract(po.result, '$.status') = 'applied'
        ) credit_ops
        JOIN (
          SELECT a.id AS allocation_id, a.group_id, a.credit_lot_id,
            SUM(a.amount_cents) OVER (PARTITION BY a.group_id ORDER BY a.id) AS cumulative_credit,
            SUM(a.amount_cents) OVER (PARTITION BY a.group_id ORDER BY a.id) - a.amount_cents AS previous_credit
          FROM credit_allocations a
          WHERE a.room_id IS NULL
        ) allocations ON allocations.group_id = credit_ops.group_id
      ) intersections
      WHERE MIN(intersections.operation_end, intersections.allocation_end) -
        MAX(intersections.operation_start, intersections.allocation_start) > 0
    ) durable
    WHERE durable.amount_cents > 0
    """)

    execute("""
    INSERT INTO cash_allocations
      (group_id, room_id, cash_payment_id, amount_cents, inserted_at, updated_at)
    SELECT funding.group_id, room.id, funding.cash_payment_id,
      MIN(funding.funding_end, room.cumulative_due) -
        MAX(funding.funding_start, room.cumulative_due - room.deposit_due_cents),
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM (
      SELECT segments.*,
        SUM(amount_cents) OVER (
          PARTITION BY group_id ORDER BY tier, operation_order, suborder
        ) AS funding_end,
        SUM(amount_cents) OVER (
          PARTITION BY group_id ORDER BY tier, operation_order, suborder
        ) - amount_cents AS funding_start
      FROM room_funding_segments segments
    ) funding
    JOIN (
      SELECT rooms.*,
        SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position) AS cumulative_due
      FROM rooms
    ) room ON room.group_id = funding.group_id
    WHERE funding.credit_lot_id IS NULL
      AND MIN(funding.funding_end, room.cumulative_due) -
      MAX(funding.funding_start, room.cumulative_due - room.deposit_due_cents) > 0
    """)

    execute("""
    INSERT INTO credit_allocations
      (group_id, room_id, credit_lot_id, amount_cents, inserted_at, updated_at)
    SELECT funding.group_id, room.id, funding.credit_lot_id,
      MIN(funding.funding_end, room.cumulative_due) -
        MAX(funding.funding_start, room.cumulative_due - room.deposit_due_cents),
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM (
      SELECT segments.*,
        SUM(amount_cents) OVER (
          PARTITION BY group_id ORDER BY tier, operation_order, suborder
        ) AS funding_end,
        SUM(amount_cents) OVER (
          PARTITION BY group_id ORDER BY tier, operation_order, suborder
        ) - amount_cents AS funding_start
      FROM room_funding_segments segments
    ) funding
    JOIN (
      SELECT rooms.*,
        SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position) AS cumulative_due
      FROM rooms
    ) room ON room.group_id = funding.group_id
    WHERE funding.credit_lot_id IS NOT NULL
      AND MIN(funding.funding_end, room.cumulative_due) -
        MAX(funding.funding_start, room.cumulative_due - room.deposit_due_cents) > 0
    """)

    execute("DELETE FROM credit_allocations WHERE room_id IS NULL")
    execute("DROP TABLE room_funding_segments")
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_allocations) do
      remove :room_id
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
