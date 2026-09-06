defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "release-03 funding is allocated immediately with the senior block before durable commit order" do
    database =
      Path.join(System.tmp_dir!(), "group-stay-upgrade-#{System.unique_integer([:positive])}.db")

    start_supervised!(
      {UpgradeRepo,
       database: database, pool: DBConnection.ConnectionPool, pool_size: 1, journal_mode: :delete}
    )

    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_825_020_000)

    sql!("""
    INSERT INTO groups
      (group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
       status, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
       cash_refunded_cents, cash_retained_cents, revision, policy_version,
       cash_paid_cents, credit_paid_cents, cash_converted_to_credit_cents)
    VALUES
      ('upgrade', 'guest', 'hotel', '2026-01-01', '2026-03-01', '2026-03-02',
       'flexible', 'active', 15000, 3000, 2400, 0, 0, 3, 'flex-14', 1200, 1200, 0)
    """)

    sql!("""
    INSERT INTO rooms (group_id, position, room_id, nightly_rate_cents)
    VALUES ('upgrade', 0, 'one', 5000),
           ('upgrade', 1, 'two', 5000),
           ('upgrade', 2, 'three', 5000)
    """)

    sql!("""
    INSERT INTO partner_operations
      (commit_order, operation_id, operation_type, submission, result)
    VALUES
      (1, 'durable-credit', 'apply_hotel_credit',
       '{"operation_id":"durable-credit","type":"apply_hotel_credit","occurred_on":"2026-02-10","group_id":"upgrade","amount_cents":700}',
       '{"operation_id":"durable-credit","status":"applied","group_id":"upgrade","amount_cents":700,"revision":2}'),
      (2, 'durable-cash', 'record_cash_payment',
       '{"operation_id":"durable-cash","type":"record_cash_payment","occurred_on":"2026-01-10","group_id":"upgrade","amount_cents":700}',
       '{"operation_id":"durable-cash","status":"applied","group_id":"upgrade","amount_cents":700,"revision":3}')
    """)

    sql!("""
    INSERT INTO credit_lots
      (id, guest_id, source_operation_id, remaining_cents, issued_on, expires_on)
    VALUES (1, 'guest', 'source', 0, '2026-01-01', '2027-01-01')
    """)

    sql!("""
    INSERT INTO credit_allocations (credit_lot_id, group_id, amount_cents)
    VALUES (1, 'upgrade', 1200)
    """)

    before_balances =
      sql!("SELECT cash_paid_cents, credit_paid_cents FROM groups WHERE group_id = 'upgrade'").rows

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_825_030_000)

    assert sql!("""
           SELECT room_id, cash_paid_cents, credit_paid_cents
             FROM rooms
            WHERE group_id = 'upgrade'
            ORDER BY position
           """).rows == [
             ["one", 500, 500],
             ["two", 300, 700],
             ["three", 400, 0]
           ]

    assert sql!("""
           SELECT r.room_id, a.funding_type,
                  COALESCE(a.payment_operation_id, a.funding_operation_id, 'senior'),
                  a.amount_cents
             FROM room_funding_allocations a
             JOIN rooms r ON r.id = a.room_id
            ORDER BY CASE a.funding_type WHEN 'cash' THEN 0 ELSE 1 END, a.id
           """).rows == [
             ["one", "cash", "senior", 500],
             ["two", "cash", "durable-cash", 300],
             ["three", "cash", "durable-cash", 400],
             ["one", "credit", "senior", 500],
             ["two", "credit", "durable-credit", 700]
           ]

    assert sql!(
             "SELECT cash_paid_cents, credit_paid_cents FROM groups WHERE group_id = 'upgrade'"
           ).rows ==
             before_balances

    assert sql!("SELECT amount_cents FROM credit_allocations WHERE group_id = 'upgrade'").rows ==
             [[1200]]

    sql!("""
    INSERT INTO groups
      (group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
       policy_version, status, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
       cash_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents,
       cash_converted_to_credit_cents, cash_reduced_cents, cash_charged_back_cents, revision)
    VALUES
      ('settled', 'guest', 'hotel', '2026-01-01', '2026-03-01', '2026-03-02',
       'flexible', 'flex-14', 'cancelled', 0, 0, 0, 0, 0, 300, 200, 100, 0, 0, 4)
    """)

    sql!("""
    INSERT INTO cash_payments
      (payment_operation_id, original_group_id, recorded_cents, held_cents,
       refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents,
       charged_back_cents)
    VALUES ('old-payment', 'settled', 600, 0, 300, 200, 100, 0, 0)
    """)

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_825_040_000)

    assert sql!("""
           SELECT participated_in_transfer
             FROM cash_payments
            WHERE payment_operation_id = 'old-payment'
           """).rows == [[0]]

    assert sql!("""
           SELECT group_id, disposition, amount_cents
             FROM cash_payment_dispositions
            WHERE payment_operation_id = 'old-payment'
            ORDER BY disposition
           """).rows == [
             ["settled", "converted_to_credit", 100],
             ["settled", "refunded", 300],
             ["settled", "retained", 200]
           ]
  end

  defp sql!(statement), do: Ecto.Adapters.SQL.query!(UpgradeRepo, statement, [])
end
