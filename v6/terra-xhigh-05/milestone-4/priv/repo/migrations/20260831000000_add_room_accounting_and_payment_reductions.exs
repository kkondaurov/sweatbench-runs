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

    # Earlier releases stored only group totals.  A room's stay length and rate
    # are enough to recover its original lodging and deposit requirement.
    execute("""
    UPDATE group_rooms
    SET lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.reservation_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.reservation_id))
          AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = group_rooms.reservation_id) = 'flexible'
            THEN CAST((nightly_rate_cents * CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.reservation_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.reservation_id))
              AS INTEGER
            ) * 20 + 50) / 100 AS INTEGER)
          ELSE nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.reservation_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.reservation_id))
            AS INTEGER
          )
        END,
        status = CASE
          WHEN (SELECT status FROM groups WHERE groups.id = group_rooms.reservation_id) = 'active'
            THEN 'active'
          ELSE 'cancelled'
        END
    """)

    create table(:cash_payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:reservation_id])

    create table(:cash_room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :cash_payment_id, references(:cash_payments, type: :binary_id, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_room_allocations, [:room_id])
    create index(:cash_room_allocations, [:cash_payment_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :source_operation_id, :string
    end

    create table(:room_credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :room_id, references(:group_rooms, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_application_id,
          references(:credit_applications, type: :binary_id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_credit_allocations, [:room_id])
    create index(:room_credit_allocations, [:credit_application_id])

    create table(:credit_lot_contributions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :cash_payment_id, references(:cash_payments, type: :binary_id, on_delete: :delete_all)
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:cash_payment_id])

    # Recreate durable cash-payment identities for active reservations.  The
    # older aggregate is then split into an unattributed senior block followed
    # by these records in audit commit order.
    execute("""
    INSERT INTO cash_payments
      (id, payment_operation_id, reservation_id, recorded_cents,
       refunded_cents, retained_cents, converted_to_credit_cents,
       reduced_cents, charged_back_cents, inserted_at, updated_at)
    SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(6))),
       operation_id,
       groups.id,
       CAST(json_extract(result, '$.amount_cents') AS INTEGER),
       CASE
         WHEN groups.status = 'cancelled' AND groups.cancelled_refunded_cents > 0
           THEN CAST(json_extract(result, '$.amount_cents') AS INTEGER)
         ELSE 0
       END,
       CASE
         WHEN groups.status = 'cancelled' AND groups.cancelled_retained_cents > 0
           THEN CAST(json_extract(result, '$.amount_cents') AS INTEGER)
         ELSE 0
       END,
       CASE
         WHEN groups.status = 'cancelled' AND groups.cancelled_cash_converted_to_credit_cents > 0
           THEN CAST(json_extract(result, '$.amount_cents') AS INTEGER)
         ELSE 0
       END,
       0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM partner_operations
    JOIN groups ON groups.group_id = json_extract(result, '$.group_id')
    WHERE operation_type = 'record_cash_payment'
      AND json_extract(result, '$.status') = 'applied'
    """)

    # Funding from before durable operations has no payment identity. It is
    # allocated first in room order and deliberately remains NULL so it cannot
    # be targeted by reductions or chargebacks.
    execute("""
    WITH recorded_funding AS (
      SELECT p.reservation_id, p.id AS cash_payment_id, p.recorded_cents,
             o.id AS funding_order
      FROM cash_payments p
      JOIN partner_operations o ON o.operation_id = p.payment_operation_id
      JOIN groups g ON g.id = p.reservation_id
      WHERE g.status = 'active'
    ), legacy_funding AS (
      SELECT g.id AS reservation_id, NULL AS cash_payment_id,
             MAX(0, g.cash_paid_cents - COALESCE(SUM(r.recorded_cents), 0)) AS recorded_cents,
             0 AS funding_order
      FROM groups g
      LEFT JOIN recorded_funding r ON r.reservation_id = g.id
      WHERE g.status = 'active'
      GROUP BY g.id, g.cash_paid_cents
    ), funding AS (
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order
      FROM legacy_funding
      UNION ALL
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order
      FROM recorded_funding
    ), ordered_funding AS (
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order,
             COALESCE(SUM(recorded_cents) OVER (
               PARTITION BY reservation_id
               ORDER BY funding_order, cash_payment_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding_cash
      FROM funding
      WHERE recorded_cents > 0
    ), ordered_rooms AS (
      SELECT r.id, r.reservation_id, r.deposit_due_cents,
             COALESCE(SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.reservation_id
               ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding_due
      FROM group_rooms r
    ), allocations AS (
      SELECT r.id AS room_id, f.cash_payment_id,
             MAX(0, MIN(f.preceding_cash + f.recorded_cents,
                         r.preceding_due + r.deposit_due_cents) -
                    MAX(f.preceding_cash, r.preceding_due)) AS amount_cents
      FROM ordered_rooms r
      JOIN groups g ON g.id = r.reservation_id
      JOIN ordered_funding f ON f.reservation_id = r.reservation_id
      WHERE g.status = 'active'
    )
    INSERT INTO cash_room_allocations
      (id, room_id, cash_payment_id, amount_cents, inserted_at, updated_at)
    SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(6))),
           room_id, cash_payment_id, amount_cents, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM allocations
    WHERE amount_cents > 0
    """)

    execute("""
    UPDATE group_rooms
    SET cash_paid_cents = COALESCE((
      SELECT SUM(a.amount_cents)
      FROM cash_room_allocations a
      WHERE a.room_id = group_rooms.id
    ), 0)
    """)

    # Existing credit applications are the other part of the senior block.  The
    # application insertion order is the best durable ordering retained by the
    # prior schema and preserves the lot-consumption sequence.
    execute("""
    WITH ordered_rooms AS (
      SELECT r.id, r.reservation_id, r.deposit_due_cents,
             COALESCE(SUM(r.deposit_due_cents) OVER (
               PARTITION BY r.reservation_id
               ORDER BY r.position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding_due
      FROM group_rooms r
      WHERE r.status = 'active'
    ), ordered_apps AS (
      SELECT a.id, a.reservation_id, a.amount_cents,
             COALESCE(SUM(a.amount_cents) OVER (
               PARTITION BY a.reservation_id
               ORDER BY a.inserted_at, a.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding_credit
      FROM credit_applications a
    ), allocations AS (
      SELECT r.id AS room_id, a.id AS credit_application_id,
             MAX(0, MIN(a.preceding_credit + a.amount_cents,
                         g.cash_paid_cents + r.preceding_due + r.deposit_due_cents) -
                    MAX(a.preceding_credit, g.cash_paid_cents + r.preceding_due)) AS amount_cents
      FROM ordered_rooms r
      JOIN groups g ON g.id = r.reservation_id
      JOIN ordered_apps a ON a.reservation_id = r.reservation_id
      WHERE g.status = 'active'
    )
    INSERT INTO room_credit_allocations
      (id, room_id, credit_application_id, amount_cents, inserted_at, updated_at)
    SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(6))),
           room_id, credit_application_id, amount_cents,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM allocations
    WHERE amount_cents > 0
    """)

    execute("""
    UPDATE group_rooms
    SET credit_paid_cents = COALESCE((
      SELECT SUM(a.amount_cents)
      FROM room_credit_allocations a
      WHERE a.room_id = group_rooms.id
    ), 0)
    """)

    # A cash payment recorded under the durable-operations release may already
    # have been converted into an older credit lot. Rebuild the payment's share
    # of that lot so a subsequent chargeback can revoke precisely its rounded
    # entitlement. Older, unattributed funding remains the senior NULL block.
    execute("""
    WITH converted_lots AS (
      SELECT l.id AS credit_lot_id, g.id AS reservation_id,
             g.cash_paid_cents, o.id AS cancellation_order
      FROM credit_lots l
      JOIN partner_operations o ON o.operation_id = l.source_operation_id
      JOIN groups g ON g.group_id = json_extract(o.result, '$.group_id')
      WHERE g.status = 'cancelled'
        AND g.cancelled_cash_converted_to_credit_cents > 0
        AND o.operation_type = 'cancel_group'
        AND json_extract(o.result, '$.status') = 'applied'
    ), recorded_funding AS (
      SELECT p.reservation_id, p.id AS cash_payment_id, p.recorded_cents,
             o.id AS funding_order
      FROM cash_payments p
      JOIN partner_operations o ON o.operation_id = p.payment_operation_id
      JOIN converted_lots l ON l.reservation_id = p.reservation_id
    ), legacy_funding AS (
      SELECT l.reservation_id, NULL AS cash_payment_id,
             MAX(0, l.cash_paid_cents - COALESCE(SUM(r.recorded_cents), 0)) AS recorded_cents,
             0 AS funding_order
      FROM converted_lots l
      LEFT JOIN recorded_funding r ON r.reservation_id = l.reservation_id
      GROUP BY l.reservation_id, l.cash_paid_cents
    ), funding AS (
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order
      FROM legacy_funding
      UNION ALL
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order
      FROM recorded_funding
    ), ordered_funding AS (
      SELECT reservation_id, cash_payment_id, recorded_cents, funding_order,
             COALESCE(SUM(recorded_cents) OVER (
               PARTITION BY reservation_id
               ORDER BY funding_order, cash_payment_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS preceding_principal
      FROM funding
      WHERE recorded_cents > 0
    ), contributions AS (
      SELECT l.credit_lot_id, f.cash_payment_id, f.recorded_cents,
             f.preceding_principal,
             f.funding_order
      FROM converted_lots l
      JOIN ordered_funding f ON f.reservation_id = l.reservation_id
    )
    INSERT INTO credit_lot_contributions
      (id, credit_lot_id, cash_payment_id, principal_cents, entitlement_cents,
       position, inserted_at, updated_at)
    SELECT lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
           lower(hex(randomblob(6))),
           credit_lot_id,
           cash_payment_id,
           recorded_cents,
           (preceding_principal + recorded_cents) +
             CAST(((preceding_principal + recorded_cents) * 10 + 50) / 100 AS INTEGER) -
             preceding_principal -
             CAST((preceding_principal * 10 + 50) / 100 AS INTEGER),
           funding_order,
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM contributions
    """)
  end

  def down do
    drop table(:credit_lot_contributions)
    drop table(:room_credit_allocations)

    alter table(:credit_applications) do
      remove :source_operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop table(:cash_room_allocations)
    drop table(:cash_payments)

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
