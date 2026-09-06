defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  alias GroupStay.RoomAccountingMigrationTest.LegacyRepo

  @migrations "priv/repo/migrations"

  # Migrations released with this change.
  @to 20_260_829_000_000
  # The durable-operations release that preceded it.
  @pre 20_260_827_000_000

  defp query!(sql), do: Ecto.Adapters.SQL.query!(LegacyRepo, sql, [])

  setup do
    # Other tests load the same migration modules into this VM; drop them so
    # they are defined once per run.
    for {module, _path} <- :code.all_loaded() do
      if Atom.to_string(module) =~ "GroupStay.Repo.Migrations" do
        :code.purge(module)
        :code.delete(module)
      end
    end

    :ok
  end

  test "room allocations bring pre-durable funding forward as a senior block" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_room_accounting_#{System.unique_integer([:positive])}.db"
      )

    File.rm(database)

    start_supervised!({LegacyRepo, database: database, busy_timeout: 30_000})
    on_exit(fn -> File.rm(database) end)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @pre)

    query!("""
    INSERT INTO groups (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
                        rate_plan, status, revision, deposit_paid_cents, refunded_cents,
                        retained_cents, policy_version, cash_paid_cents, credit_paid_cents,
                        cash_converted_to_credit_cents, inserted_at, updated_at)
    VALUES
      ('a1111111-1111-1111-1111-111111111111', 'legacy-g1', 'g-1', 'p-1',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'active', 4, 6000, 0, 0,
       'flex-14', 6000, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('a2222222-2222-2222-2222-222222222222', 'legacy-g2', 'g-2', 'p-1',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'active', 3, 1500, 0, 0,
       'flex-14', 500, 1000, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('a3333333-3333-3333-3333-333333333333', 'legacy-g3', 'g-3', 'p-1',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'cancelled', 3, 900, 900, 0,
       'flex-14', 0, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('a4444444-4444-4444-4444-444444444444', 'legacy-g4', 'g-4', 'p-1',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'active', 3, 4000, 0, 0,
       'flex-14', 1000, 3000, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('a5555555-5555-5555-5555-555555555555', 'legacy-g5', 'g-5', 'p-1',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'cancelled', 4, 0, 3000, 0,
       'flex-14', 3000, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    query!("""
    INSERT INTO rooms (id, group_id, room_id, nightly_rate_cents, lodging_cents, deposit_cents,
                       "position", inserted_at, updated_at)
    VALUES
      ('b1111111-1111-1111-1111-111111111111', 'a1111111-1111-1111-1111-111111111111', 'r1',
       10000, 30000, 3000, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b2222222-2222-2222-2222-222222222222', 'a1111111-1111-1111-1111-111111111111', 'r2',
       10000, 30000, 4000, 2, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b3333333-3333-3333-3333-333333333333', 'a2222222-2222-2222-2222-222222222222', 'r5',
       10000, 30000, 1000, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b4444444-4444-4444-4444-444444444444', 'a2222222-2222-2222-2222-222222222222', 'r6',
       10000, 30000, 1000, 2, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b5555555-5555-5555-5555-555555555555', 'a3333333-3333-3333-3333-333333333333', 'r7',
       10000, 30000, 3000, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b6666666-6666-6666-6666-666666666666', 'a4444444-4444-4444-4444-444444444444', 'r8',
       10000, 30000, 5000, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b7777777-7777-7777-7777-777777777777', 'a4444444-4444-4444-4444-444444444444', 'r9',
       10000, 30000, 5000, 2, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b8888888-8888-8888-8888-888888888888', 'a5555555-5555-5555-5555-555555555555', 'r10',
       10000, 30000, 1500, 1, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('b9999999-9999-9999-9999-999999999999', 'a5555555-5555-5555-5555-555555555555', 'r11',
       10000, 30000, 1500, 2, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    query!("""
    INSERT INTO operations (operation_id, type, payload, result, inserted_at, updated_at)
    VALUES
      ('pay-A', 'record_cash_payment',
       '{"operation_id":"pay-A","type":"record_cash_payment","occurred_on":"2027-06-01","group_id":"legacy-g1","amount_cents":2000}',
       '{"operation_id":"pay-A","status":"applied","group_id":"legacy-g1","amount_cents":2000,"outstanding_deposit_cents":4000,"revision":2}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('pay-B', 'record_cash_payment',
       '{"operation_id":"pay-B","type":"record_cash_payment","occurred_on":"2026-01-01","group_id":"legacy-g1","amount_cents":2000}',
       '{"operation_id":"pay-B","status":"applied","group_id":"legacy-g1","amount_cents":2000,"outstanding_deposit_cents":2000,"revision":3}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('pay-C', 'record_cash_payment',
       '{"operation_id":"pay-C","type":"record_cash_payment","occurred_on":"2026-10-04","group_id":"legacy-g4","amount_cents":1000}',
       '{"operation_id":"pay-C","status":"applied","group_id":"legacy-g4","amount_cents":1000,"outstanding_deposit_cents":9000,"revision":2}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('credit-op-1', 'apply_hotel_credit',
       '{"operation_id":"credit-op-1","type":"apply_hotel_credit","occurred_on":"2026-11-01","group_id":"legacy-g4","amount_cents":3000}',
       '{"operation_id":"credit-op-1","status":"applied","group_id":"legacy-g4","amount_cents":3000,"outstanding_deposit_cents":6000,"revision":3}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('pay-E', 'record_cash_payment',
       '{"operation_id":"pay-E","type":"record_cash_payment","occurred_on":"2026-10-04","group_id":"legacy-g5","amount_cents":1000}',
       '{"operation_id":"pay-E","status":"applied","group_id":"legacy-g5","amount_cents":1000,"outstanding_deposit_cents":2000,"revision":3}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('pay-F', 'record_cash_payment',
       '{"operation_id":"pay-F","type":"record_cash_payment","occurred_on":"2026-10-04","group_id":"legacy-g5","amount_cents":1000}',
       '{"operation_id":"pay-F","status":"applied","group_id":"legacy-g5","amount_cents":1000,"outstanding_deposit_cents":1000,"revision":4}',
       '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    query!("""
    INSERT INTO credit_lots (id, guest_id, source_operation_id, expires_on, remaining_cents,
                             applied_cents, inserted_at, updated_at)
    VALUES
      ('c1111111-1111-1111-1111-111111111111', 'g-2', 'legacy-lot-2', '2030-01-01', 0, 1000,
       '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('c2222222-2222-2222-2222-222222222222', 'g-4', 'legacy-lot-4', '2030-01-01', 0, 3000,
       '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    query!("""
    INSERT INTO credit_applications (id, lot_id, group_id, amount_cents, applied_on, settlement,
                                     inserted_at, updated_at)
    VALUES
      ('d1111111-1111-1111-1111-111111111111', 'c1111111-1111-1111-1111-111111111111',
       'a2222222-2222-2222-2222-222222222222', 400, '2026-05-10', 'applied',
       '2026-05-10 00:00:00', '2026-05-10 00:00:00'),
      ('d2222222-2222-2222-2222-222222222222', 'c1111111-1111-1111-1111-111111111111',
       'a2222222-2222-2222-2222-222222222222', 600, '2026-04-05', 'applied',
       '2026-04-05 00:00:00', '2026-04-05 00:00:00'),
      ('d3333333-3333-3333-3333-333333333333', 'c2222222-2222-2222-2222-222222222222',
       'a4444444-4444-4444-4444-444444444444', 1200, '2026-11-01', 'applied',
       '2026-11-01 00:00:00', '2026-11-01 00:00:00'),
      ('d4444444-4444-4444-4444-444444444444', 'c2222222-2222-2222-2222-222222222222',
       'a4444444-4444-4444-4444-444444444444', 1800, '2026-11-01', 'applied',
       '2026-11-01 00:00:00', '2026-11-01 00:00:00')
    """)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @to)

    allocations =
      query!("""
      SELECT g.group_id, r.room_id, a.kind, a.amount_cents,
             COALESCE(a.payment_operation_id, ''), COALESCE(a.credit_application_id, ''),
             a.fill_position
      FROM room_allocations a
      JOIN rooms r ON r.id = a.room_id
      JOIN groups g ON g.id = a.group_id
      ORDER BY g.group_id, a.fill_position
      """).rows

    # legacy-g1: senior cash first, then durable payments in commit order,
    # regardless of occurred_on (pay-B's date precedes pay-A's).
    assert Enum.filter(allocations, fn [group_id, _, _, _, _, _, _] -> group_id == "legacy-g1" end) ==
             [
               # room_id  kind    amount  payment  application fill
               ["legacy-g1", "r1", "cash", 2000, "", "", 1],
               ["legacy-g1", "r1", "cash", 1000, "pay-A", "", 2],
               ["legacy-g1", "r2", "cash", 1000, "pay-A", "", 3],
               ["legacy-g1", "r2", "cash", 2000, "pay-B", "", 4]
             ]

    # legacy-g2: senior cash first, then legacy credit in original
    # consumption order (600 on 2026-04-05 before 400 on 2026-05-10).
    assert Enum.filter(allocations, fn [group_id, _, _, _, _, _, _] -> group_id == "legacy-g2" end) ==
             [
               ["legacy-g2", "r5", "cash", 500, "", "", 1],
               ["legacy-g2", "r5", "credit", 500, "", "d2222222-2222-2222-2222-222222222222", 2],
               ["legacy-g2", "r6", "credit", 100, "", "d2222222-2222-2222-2222-222222222222", 3],
               ["legacy-g2", "r6", "credit", 400, "", "d1111111-1111-1111-1111-111111111111", 4]
             ]

    # legacy-g4: durable payment first, then the matched credit operation.
    assert Enum.filter(allocations, fn [group_id, _, _, _, _, _, _] -> group_id == "legacy-g4" end) ==
             [
               ["legacy-g4", "r8", "cash", 1000, "pay-C", "", 1],
               ["legacy-g4", "r8", "credit", 1200, "", "d3333333-3333-3333-3333-333333333333", 2],
               ["legacy-g4", "r8", "credit", 1800, "", "d4444444-4444-4444-4444-444444444444", 3]
             ]

    # The credit applications were classified by their retained operation.
    apps =
      query!("""
      SELECT id, COALESCE(operation_id, '') FROM credit_applications ORDER BY id
      """).rows

    assert apps == [
             ["d1111111-1111-1111-1111-111111111111", ""],
             ["d2222222-2222-2222-2222-222222222222", ""],
             ["d3333333-3333-3333-3333-333333333333", "credit-op-1"],
             ["d4444444-4444-4444-4444-444444444444", "credit-op-1"]
           ]

    # Cancelled groups' rooms are marked cancelled; active groups' rooms stay
    # active, and no aggregate balance changed.
    assert query!("SELECT status FROM rooms WHERE room_id = 'r7'").rows == [["cancelled"]]

    assert query!("""
             SELECT COUNT(*) FROM rooms r
             JOIN groups g ON g.id = r.group_id
             WHERE g.status = 'cancelled' AND r.status <> 'cancelled'
           """).rows == [[0]]

    assert query!("""
             SELECT g.group_id, g.cash_paid_cents, g.credit_paid_cents, g.deposit_paid_cents,
                    g.refunded_cents, g.retained_cents, g.cash_converted_to_credit_cents
             FROM groups g ORDER BY g.group_id
           """).rows == [
             ["legacy-g1", 6000, 0, 6000, 0, 0, 0],
             ["legacy-g2", 500, 1000, 1500, 0, 0, 0],
             ["legacy-g3", 0, 0, 900, 900, 0, 0],
             ["legacy-g4", 1000, 3000, 4000, 0, 0, 0],
             ["legacy-g5", 3000, 0, 0, 3000, 0, 0]
           ]

    assert query!("SELECT SUM(amount_cents), COUNT(*) FROM room_allocations").rows ==
             [[14_500, 15]]

    assert query!("""
             SELECT g.group_id, SUM(a.amount_cents)
             FROM room_allocations a JOIN groups g ON g.id = a.group_id
             GROUP BY g.group_id ORDER BY g.group_id
           """).rows == [
             ["legacy-g1", 6000],
             ["legacy-g2", 1500],
             ["legacy-g4", 4000],
             ["legacy-g5", 3000]
           ]

    # Credit allocations preserve each application's amount.
    assert query!("""
             SELECT COALESCE(a.credit_application_id, ''), SUM(a.amount_cents)
             FROM room_allocations a
             WHERE a.credit_application_id IS NOT NULL
             GROUP BY a.credit_application_id
             ORDER BY a.credit_application_id
           """).rows == [
             ["d1111111-1111-1111-1111-111111111111", 400],
             ["d2222222-2222-2222-2222-222222222222", 600],
             ["d3333333-3333-3333-3333-333333333333", 1200],
             ["d4444444-4444-4444-4444-444444444444", 1800]
           ]

    # Cancelled groups keep per-payment settlement totals in agreement with
    # the aggregate columns: legacy cash is settled first, then durable
    # payments in commit order.
    assert query!("""
             SELECT payment_operation_id, recorded_cents, refunded_cents, retained_cents,
                    converted_cents, reduced_cents, charged_back_cents
             FROM payment_dispositions ORDER BY payment_operation_id
           """).rows == [
             ["pay-E", 1000, 1000, 0, 0, 0, 0],
             ["pay-F", 1000, 1000, 0, 0, 0, 0]
           ]

    # The deposit-transfers release numbers existing allocations globally in
    # their allocation order and marks the transferred-participation flag
    # false for payments that existed before transfers were possible.
    assert query!("""
             SELECT g.group_id, a.fill_position, a.creation_order
             FROM room_allocations a
             JOIN groups g ON g.id = a.group_id
             ORDER BY a.creation_order
           """).rows == [
             ["legacy-g1", 1, 1],
             ["legacy-g1", 2, 2],
             ["legacy-g1", 3, 3],
             ["legacy-g1", 4, 4],
             ["legacy-g2", 1, 5],
             ["legacy-g2", 2, 6],
             ["legacy-g2", 3, 7],
             ["legacy-g2", 4, 8],
             ["legacy-g4", 1, 9],
             ["legacy-g4", 2, 10],
             ["legacy-g4", 3, 11],
             ["legacy-g5", 1, 12],
             ["legacy-g5", 2, 13],
             ["legacy-g5", 3, 14],
             ["legacy-g5", 4, 15]
           ]

    assert query!("""
             SELECT payment_operation_id, participated_in_transfer
             FROM payment_dispositions ORDER BY payment_operation_id
           """).rows == [
             ["pay-E", 0],
             ["pay-F", 0]
           ]
  end
end
