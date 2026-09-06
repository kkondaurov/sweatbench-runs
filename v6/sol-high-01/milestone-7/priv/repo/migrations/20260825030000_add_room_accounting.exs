defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:original_group_id])

    create table(:room_funding_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :funding_type, :string, null: false
      add :payment_operation_id, :string
      add :funding_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :amount_cents, :integer, null: false
    end

    create index(:room_funding_allocations, [:room_id, :id])
    create index(:room_funding_allocations, [:payment_operation_id, :id])
    create index(:room_funding_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id, :id])

    flush()
    backfill_rooms_and_payments()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_funding_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill_rooms_and_payments do
    execute("""
    UPDATE rooms
       SET status = CASE
             WHEN (SELECT status FROM groups WHERE groups.group_id = rooms.group_id) = 'cancelled'
             THEN 'cancelled' ELSE 'active' END,
           lodging_total_cents = nightly_rate_cents * CAST(
             julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
             julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER
           )
    """)

    execute("""
    UPDATE rooms
       SET deposit_due_cents = CASE
             WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
             THEN lodging_total_cents
             ELSE CAST((lodging_total_cents * 20 + 50) / 100 AS INTEGER)
           END
    """)

    execute("""
    INSERT INTO cash_payments
      (payment_operation_id, original_group_id, recorded_cents, held_cents,
       refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents,
       charged_back_cents)
    SELECT po.operation_id,
           json_extract(po.result, '$.group_id'),
           json_extract(po.result, '$.amount_cents'),
           CASE WHEN g.status = 'active' THEN json_extract(po.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.cash_refunded_cents > 0 THEN json_extract(po.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.cash_retained_cents > 0 THEN json_extract(po.result, '$.amount_cents') ELSE 0 END,
           CASE WHEN g.cash_converted_to_credit_cents > 0 THEN json_extract(po.result, '$.amount_cents') ELSE 0 END,
           0, 0
      FROM partner_operations po
      JOIN groups g ON g.group_id = json_extract(po.result, '$.group_id')
     WHERE po.operation_type = 'record_cash_payment'
       AND json_extract(po.result, '$.status') = 'applied'
    """)

    execute(allocation_insert_sql("cash"))
    execute(allocation_insert_sql("credit"))

    execute("""
    UPDATE rooms
       SET cash_paid_cents = COALESCE((
             SELECT SUM(rfa.amount_cents)
               FROM room_funding_allocations rfa
              WHERE rfa.room_id = rooms.id AND rfa.funding_type = 'cash'
           ), 0),
           credit_paid_cents = COALESCE((
             SELECT SUM(rfa.amount_cents)
               FROM room_funding_allocations rfa
              WHERE rfa.room_id = rooms.id AND rfa.funding_type = 'credit'
           ), 0)
    """)
  end

  defp allocation_insert_sql(type) do
    {extra_ctes, selection} =
      case type do
        "cash" ->
          {"",
           """
           SELECT r.room_id, 'cash', b.payment_operation_id, b.funding_operation_id,
                  NULL, MIN(r.room_end, b.block_end) - MAX(r.room_start, b.block_start)
             FROM room_intervals r
             JOIN funding_blocks b ON b.group_id = r.group_id AND b.funding_type = 'cash'
            WHERE MIN(r.room_end, b.block_end) > MAX(r.room_start, b.block_start)
            ORDER BY b.group_id, b.block_start, r.room_start
           """}

        "credit" ->
          {"""
           , lot_seeds AS (
             SELECT ca.group_id, ca.id AS consumption_order, ca.credit_lot_id, ca.amount_cents
               FROM credit_allocations ca
               JOIN groups g ON g.group_id = ca.group_id
              WHERE g.status = 'active'
           ), lot_blocks AS (
             SELECT group_id, credit_lot_id,
                    COALESCE(SUM(amount_cents) OVER (
                      PARTITION BY group_id ORDER BY consumption_order
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                    ), 0) AS lot_start,
                    SUM(amount_cents) OVER (
                      PARTITION BY group_id ORDER BY consumption_order
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                    ) AS lot_end
               FROM lot_seeds
           ), credit_segments AS (
             SELECT b.group_id, b.funding_operation_id, l.credit_lot_id,
                    b.block_start + MAX(b.credit_start, l.lot_start) - b.credit_start AS segment_start,
                    b.block_start + MIN(b.credit_end, l.lot_end) - b.credit_start AS segment_end
               FROM funding_blocks b
               JOIN lot_blocks l ON l.group_id = b.group_id
              WHERE b.funding_type = 'credit'
                AND MIN(b.credit_end, l.lot_end) > MAX(b.credit_start, l.lot_start)
           )
           """,
           """
           SELECT r.room_id, 'credit', NULL, s.funding_operation_id,
                  s.credit_lot_id,
                  MIN(r.room_end, s.segment_end) - MAX(r.room_start, s.segment_start)
             FROM room_intervals r
             JOIN credit_segments s ON s.group_id = r.group_id
            WHERE MIN(r.room_end, s.segment_end) > MAX(r.room_start, s.segment_start)
            ORDER BY s.group_id, s.segment_start, r.room_start
           """}
      end

    """
    WITH room_intervals AS (
      SELECT r.id AS room_id, r.group_id,
             COALESCE(SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS room_start,
             SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.group_id ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS room_end
        FROM rooms r
       WHERE r.status = 'active'
    ), durable_cash AS (
      SELECT cp.original_group_id AS group_id, cp.payment_operation_id,
             po.commit_order, cp.held_cents AS amount_cents
        FROM cash_payments cp
        JOIN partner_operations po ON po.operation_id = cp.payment_operation_id
       WHERE cp.held_cents > 0
    ), durable_credit AS (
      SELECT json_extract(po.result, '$.group_id') AS group_id,
             po.operation_id, po.commit_order,
             json_extract(po.result, '$.amount_cents') AS amount_cents
        FROM partner_operations po
       WHERE po.operation_type = 'apply_hotel_credit'
         AND json_extract(po.result, '$.status') = 'applied'
    ), funding_seeds AS (
      SELECT g.group_id, 'cash' AS funding_type,
             NULL AS payment_operation_id, NULL AS funding_operation_id,
             0 AS phase, 0 AS funding_order,
             g.cash_paid_cents - COALESCE((
               SELECT SUM(dc.amount_cents) FROM durable_cash dc WHERE dc.group_id = g.group_id
             ), 0) AS amount_cents
        FROM groups g WHERE g.status = 'active'
      UNION ALL
      SELECT g.group_id, 'credit', NULL, NULL, 1, 0,
             g.credit_paid_cents - COALESCE((
               SELECT SUM(dc.amount_cents) FROM durable_credit dc WHERE dc.group_id = g.group_id
             ), 0)
        FROM groups g WHERE g.status = 'active'
      UNION ALL
      SELECT group_id, 'cash', payment_operation_id, payment_operation_id,
             2, commit_order, amount_cents FROM durable_cash
      UNION ALL
      SELECT dc.group_id, 'credit', NULL, dc.operation_id,
             2, dc.commit_order, dc.amount_cents
        FROM durable_credit dc
        JOIN groups g ON g.group_id = dc.group_id
       WHERE g.status = 'active'
    ), funding_blocks AS (
      SELECT group_id, funding_type, payment_operation_id, funding_operation_id,
             COALESCE(SUM(amount_cents) OVER (
               PARTITION BY group_id ORDER BY phase, funding_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS block_start,
             SUM(amount_cents) OVER (
               PARTITION BY group_id ORDER BY phase, funding_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS block_end,
             COALESCE(SUM(CASE WHEN funding_type = 'credit' THEN amount_cents ELSE 0 END) OVER (
               PARTITION BY group_id ORDER BY phase, funding_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS credit_start,
             SUM(CASE WHEN funding_type = 'credit' THEN amount_cents ELSE 0 END) OVER (
               PARTITION BY group_id ORDER BY phase, funding_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS credit_end
        FROM funding_seeds
       WHERE amount_cents > 0
    )
    #{extra_ctes}
    INSERT INTO room_funding_allocations
      (room_id, funding_type, payment_operation_id, funding_operation_id,
       credit_lot_id, amount_cents)
    #{selection}
    """
  end
end
