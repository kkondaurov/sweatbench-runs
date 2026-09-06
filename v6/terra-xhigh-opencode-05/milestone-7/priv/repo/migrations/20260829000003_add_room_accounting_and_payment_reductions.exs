defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments, primary_key: false) do
      add :operation_id, :string, primary_key: true

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :nothing),
          null: false

      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps()
    end

    create index(:cash_payments, [:group_id])

    create table(:room_funding_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :funding_kind, :string, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :nothing)
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:room_funding_allocations, [:group_id, :room_id])
    create index(:room_funding_allocations, [:payment_operation_id])
    create index(:room_funding_allocations, [:credit_lot_id])

    create table(:credit_lot_contributions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :cash_amount_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])

    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * CAST(julianday(
          (SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)
        ) - julianday(
          (SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)
        ) AS INTEGER),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'flexible'
            THEN CAST((nightly_rate_cents * CAST(julianday(
              (SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)
            ) - julianday(
              (SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)
            ) AS INTEGER) + 2) / 5 AS INTEGER)
          ELSE nightly_rate_cents * CAST(julianday(
            (SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)
          ) - julianday(
            (SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)
          ) AS INTEGER)
        END
    """)

    execute("""
    UPDATE rooms
    SET status = 'cancelled'
    WHERE group_id IN (SELECT group_id FROM groups WHERE status = 'cancelled')
    """)

    # Durable cash records are retained as individually reconcilable payments.
    execute("""
    INSERT INTO cash_payments (
      operation_id, group_id, recorded_cents, refunded_cents, retained_cents,
      converted_to_credit_cents, reduced_cents, charged_back_cents, inserted_at, updated_at
    )
    SELECT
      partner_operations.operation_id,
      json_extract(partner_operations.result, '$.group_id'),
      json_extract(partner_operations.result, '$.amount_cents'),
      CASE WHEN groups.status = 'cancelled' AND groups.refunded_cents > 0
        THEN json_extract(partner_operations.result, '$.amount_cents') ELSE 0 END,
      CASE WHEN groups.status = 'cancelled' AND groups.retained_cents > 0
        THEN json_extract(partner_operations.result, '$.amount_cents') ELSE 0 END,
      CASE WHEN groups.status = 'cancelled' AND groups.cash_converted_to_credit_cents > 0
        THEN json_extract(partner_operations.result, '$.amount_cents') ELSE 0 END,
      0,
      0,
      partner_operations.inserted_at,
      partner_operations.inserted_at
    FROM partner_operations
    JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
    WHERE operation_type = 'record_cash_payment'
      AND json_extract(partner_operations.result, '$.status') = 'applied'
    """)

    # Earlier releases only converted whole groups. Reconstruct each payment's telescoping
    # entitlement before the aggregate group history is split into durable and legacy portions.
    execute("""
    WITH lot_groups AS (
      SELECT credit_lots.id AS credit_lot_id, groups.group_id,
             groups.cash_converted_to_credit_cents AS converted_cents
      FROM credit_lots
      JOIN partner_operations ON partner_operations.operation_id = credit_lots.source_operation_id
      JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
      WHERE partner_operations.operation_type = 'cancel_group'
        AND json_extract(partner_operations.result, '$.status') = 'applied'
        AND groups.cash_converted_to_credit_cents > 0
    ),
    durable_totals AS (
      SELECT lot_groups.credit_lot_id,
             COALESCE(SUM(cash_payments.recorded_cents), 0) AS durable_cents
      FROM lot_groups
      LEFT JOIN cash_payments ON cash_payments.group_id = lot_groups.group_id
      GROUP BY lot_groups.credit_lot_id
    ),
    legacy_sources AS (
      SELECT lot_groups.credit_lot_id,
             MAX(lot_groups.converted_cents - durable_totals.durable_cents, 0) AS cash_amount_cents
      FROM lot_groups
      JOIN durable_totals ON durable_totals.credit_lot_id = lot_groups.credit_lot_id
    )
    INSERT INTO credit_lot_contributions (
      credit_lot_id, payment_operation_id, cash_amount_cents, entitlement_cents, inserted_at, updated_at
    )
    SELECT credit_lot_id, NULL, cash_amount_cents,
           cash_amount_cents + CAST((cash_amount_cents + 5) / 10 AS INTEGER),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM legacy_sources
    WHERE cash_amount_cents > 0
    """)

    execute("""
    WITH lot_groups AS (
      SELECT credit_lots.id AS credit_lot_id, groups.group_id,
             groups.cash_converted_to_credit_cents AS converted_cents
      FROM credit_lots
      JOIN partner_operations ON partner_operations.operation_id = credit_lots.source_operation_id
      JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
      WHERE partner_operations.operation_type = 'cancel_group'
        AND json_extract(partner_operations.result, '$.status') = 'applied'
        AND groups.cash_converted_to_credit_cents > 0
    ),
    durable_totals AS (
      SELECT lot_groups.credit_lot_id,
             COALESCE(SUM(cash_payments.recorded_cents), 0) AS durable_cents
      FROM lot_groups
      LEFT JOIN cash_payments ON cash_payments.group_id = lot_groups.group_id
      GROUP BY lot_groups.credit_lot_id
    ),
    payment_windows AS (
      SELECT lot_groups.credit_lot_id, cash_payments.operation_id,
             MAX(lot_groups.converted_cents - durable_totals.durable_cents, 0) +
               COALESCE(SUM(cash_payments.recorded_cents) OVER (
                 PARTITION BY lot_groups.credit_lot_id ORDER BY partner_operations.id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ), 0) AS previous_cents,
             MAX(lot_groups.converted_cents - durable_totals.durable_cents, 0) +
               SUM(cash_payments.recorded_cents) OVER (
                 PARTITION BY lot_groups.credit_lot_id ORDER BY partner_operations.id
               ) AS through_cents,
             cash_payments.recorded_cents
      FROM lot_groups
      JOIN durable_totals ON durable_totals.credit_lot_id = lot_groups.credit_lot_id
      JOIN cash_payments ON cash_payments.group_id = lot_groups.group_id
      JOIN partner_operations ON partner_operations.operation_id = cash_payments.operation_id
    )
    INSERT INTO credit_lot_contributions (
      credit_lot_id, payment_operation_id, cash_amount_cents, entitlement_cents, inserted_at, updated_at
    )
    SELECT credit_lot_id, operation_id, recorded_cents,
           (through_cents + CAST((through_cents + 5) / 10 AS INTEGER)) -
             (previous_cents + CAST((previous_cents + 5) / 10 AS INTEGER)),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM payment_windows
    """)

    # Group totals from earlier releases now represent only funding without a durable payment identity.
    execute("""
    UPDATE groups
    SET refunded_cents = MAX(refunded_cents - COALESCE((
          SELECT SUM(refunded_cents) FROM cash_payments WHERE cash_payments.group_id = groups.group_id
        ), 0), 0),
        retained_cents = MAX(retained_cents - COALESCE((
          SELECT SUM(retained_cents) FROM cash_payments WHERE cash_payments.group_id = groups.group_id
        ), 0), 0),
        cash_converted_to_credit_cents = MAX(cash_converted_to_credit_cents - COALESCE((
          SELECT SUM(converted_to_credit_cents) FROM cash_payments WHERE cash_payments.group_id = groups.group_id
        ), 0), 0)
    """)

    # The senior legacy block is cash followed by credit. Durable cash and credit then share one
    # stream ordered by durable-record commit order, regardless of their occurred_on values.
    execute("""
    WITH durable_cash_totals AS (
      SELECT group_id, COALESCE(SUM(recorded_cents), 0) AS amount_cents
      FROM cash_payments
      GROUP BY group_id
    ),
    durable_credit_totals AS (
      SELECT json_extract(result, '$.group_id') AS group_id,
             COALESCE(SUM(json_extract(result, '$.amount_cents')), 0) AS amount_cents
      FROM partner_operations
      WHERE operation_type = 'apply_hotel_credit'
        AND json_extract(result, '$.status') = 'applied'
      GROUP BY json_extract(result, '$.group_id')
    ),
    legacy_totals AS (
      SELECT groups.group_id,
             MAX(groups.cash_paid_cents - COALESCE(durable_cash_totals.amount_cents, 0), 0) AS cash_cents,
             MAX(groups.credit_paid_cents - COALESCE(durable_credit_totals.amount_cents, 0), 0) AS credit_cents
      FROM groups
      LEFT JOIN durable_cash_totals ON durable_cash_totals.group_id = groups.group_id
      LEFT JOIN durable_credit_totals ON durable_credit_totals.group_id = groups.group_id
      WHERE groups.status = 'active'
    ),
    credit_application_windows AS (
      SELECT credit_applications.group_id, credit_applications.credit_lot_id,
             credit_applications.id AS application_id,
             COALESCE(SUM(credit_applications.amount_cents) OVER (
               PARTITION BY credit_applications.group_id ORDER BY credit_applications.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS previous_cents,
             SUM(credit_applications.amount_cents) OVER (
               PARTITION BY credit_applications.group_id ORDER BY credit_applications.id
             ) AS through_cents
      FROM credit_applications
      JOIN groups ON groups.group_id = credit_applications.group_id
      WHERE groups.status = 'active'
    ),
    durable_credit_operations AS (
      SELECT partner_operations.id AS operation_order,
             json_extract(partner_operations.result, '$.group_id') AS group_id,
             json_extract(partner_operations.result, '$.amount_cents') AS amount_cents,
             COALESCE(SUM(json_extract(partner_operations.result, '$.amount_cents')) OVER (
               PARTITION BY json_extract(partner_operations.result, '$.group_id')
               ORDER BY partner_operations.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS previous_cents,
             SUM(json_extract(partner_operations.result, '$.amount_cents')) OVER (
               PARTITION BY json_extract(partner_operations.result, '$.group_id')
               ORDER BY partner_operations.id
             ) AS through_cents
      FROM partner_operations
      JOIN groups ON groups.group_id = json_extract(partner_operations.result, '$.group_id')
      WHERE partner_operations.operation_type = 'apply_hotel_credit'
        AND json_extract(partner_operations.result, '$.status') = 'applied'
        AND groups.status = 'active'
    ),
    sources AS (
      SELECT legacy_totals.group_id, 0 AS phase, 0 AS operation_order, 0 AS source_order,
             'cash' AS funding_kind, NULL AS payment_operation_id, NULL AS credit_lot_id,
             legacy_totals.cash_cents AS amount_cents
      FROM legacy_totals
      UNION ALL
      SELECT credit_application_windows.group_id, 0, 1, credit_application_windows.application_id,
             'credit', NULL, credit_application_windows.credit_lot_id,
             MAX(0, MIN(credit_application_windows.through_cents, legacy_totals.credit_cents) -
               credit_application_windows.previous_cents)
      FROM credit_application_windows
      JOIN legacy_totals ON legacy_totals.group_id = credit_application_windows.group_id
      UNION ALL
      SELECT cash_payments.group_id, 1, partner_operations.id, 0,
             'cash', cash_payments.operation_id, NULL, cash_payments.recorded_cents
      FROM cash_payments
      JOIN partner_operations ON partner_operations.operation_id = cash_payments.operation_id
      JOIN groups ON groups.group_id = cash_payments.group_id
      WHERE groups.status = 'active'
      UNION ALL
      SELECT durable_credit_operations.group_id, 1, durable_credit_operations.operation_order,
             credit_application_windows.application_id,
             'credit', NULL, credit_application_windows.credit_lot_id,
             MAX(0, MIN(credit_application_windows.through_cents,
               legacy_totals.credit_cents + durable_credit_operations.through_cents) -
               MAX(credit_application_windows.previous_cents,
                 legacy_totals.credit_cents + durable_credit_operations.previous_cents))
      FROM durable_credit_operations
      JOIN legacy_totals ON legacy_totals.group_id = durable_credit_operations.group_id
      JOIN credit_application_windows ON credit_application_windows.group_id = durable_credit_operations.group_id
    ),
    source_windows AS (
      SELECT group_id, phase, operation_order, source_order, funding_kind,
             payment_operation_id, credit_lot_id, amount_cents,
             COALESCE(SUM(amount_cents) OVER (
               PARTITION BY group_id ORDER BY phase, operation_order, source_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS previous_cents,
             SUM(amount_cents) OVER (
               PARTITION BY group_id ORDER BY phase, operation_order, source_order
             ) AS through_cents
      FROM sources
      WHERE amount_cents > 0
    ),
    room_windows AS (
      SELECT group_id, room_id, position,
             COALESCE(SUM(deposit_due_cents) OVER (
               PARTITION BY group_id ORDER BY position
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS previous_cents,
             SUM(deposit_due_cents) OVER (PARTITION BY group_id ORDER BY position) AS through_cents
      FROM rooms
      WHERE status = 'active'
    )
    INSERT INTO room_funding_allocations (
      group_id, room_id, funding_kind, payment_operation_id, credit_lot_id,
      amount_cents, inserted_at, updated_at
    )
    SELECT source_windows.group_id, room_windows.room_id, source_windows.funding_kind,
           source_windows.payment_operation_id, source_windows.credit_lot_id,
           MAX(0, MIN(source_windows.through_cents, room_windows.through_cents) -
             MAX(source_windows.previous_cents, room_windows.previous_cents)),
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM source_windows
    JOIN room_windows ON room_windows.group_id = source_windows.group_id
    WHERE MAX(0, MIN(source_windows.through_cents, room_windows.through_cents) -
      MAX(source_windows.previous_cents, room_windows.previous_cents)) > 0
    """)
  end

  def down do
    drop table(:credit_lot_contributions)
    drop table(:room_funding_allocations)
    drop table(:cash_payments)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end
end
