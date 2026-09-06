defmodule GroupStay.RoomAccountingMigrationTest do
  @moduledoc """
  Product request 04: upgrading a database that still carries funding from
  before durable operation records.

  A dedicated repository over a throwaway SQLite database runs the real
  migrations in order: the earlier migrations build the pre-release schema,
  legacy rows are inserted exactly as an earlier release would have left
  them, and the room-accounting migration brings that funding forward into
  room allocations — the unattributed senior block first, then funding with
  a durable operation record in commit order — without changing any
  aggregate cash, credit, or liability balance.
  """

  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @durable_operations_version 20_260_826_020_000
  @now "2026-08-26 00:00:00"

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "group_stay_room_accounting_migration_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({LegacyRepo, database: path, pool_size: 1, log: false})
    on_exit(fn -> File.rm_rf(path) end)

    migrate_to(@durable_operations_version)
    insert_legacy_data()

    {:ok, path: path}
  end

  # The migrator loads every migration source on each invocation, which
  # redefines modules already in memory; the conflicts are expected here.
  defp migrate_to(version) do
    Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(LegacyRepo, [@migrations_dir], :up, to: version, log: false)
  after
    Code.compiler_options(ignore_module_conflict: false)
  end

  defp migrate_all do
    Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(LegacyRepo, [@migrations_dir], :up, all: true, log: false)
  after
    Code.compiler_options(ignore_module_conflict: false)
  end

  test "brings legacy funding forward as the senior block, durable funding in commit order, settled rooms, and lot entitlements" do
    migrate_all()

    # The durable payment is attributed; the pre-durable one is not.
    assert payment_operation_ids("g-mig-active") == [[nil, 4000], ["op-mig-pay", 2000]]

    # Funding order: aggregate legacy cash (4000) fills room-a first, then
    # the legacy credit lot (500), then the durable payment (2000) finishes
    # room-a and starts room-b.
    assert allocations("g-mig-active", "room-a") == [
             ["cash", nil, 4000, "held"],
             ["credit", nil, 500, "held"],
             ["cash", "op-mig-pay", 1500, "held"]
           ]

    assert allocations("g-mig-active", "room-b") == [
             ["cash", "op-mig-pay", 500, "held"]
           ]

    # Rooms gained their deposit requirements and active status.
    assert room_deposits("g-mig-active") == [
             ["room-a", "active", 6000],
             ["room-b", "active", 6000]
           ]

    # No aggregate balance changed: every cent of funding is allocated,
    # attributed to exactly the payment or credit lot that supplied it.
    assert funding_totals("g-mig-active") == [
             ["cash", nil, 4000, "held"],
             ["credit", nil, 500, "held"],
             ["cash", "op-mig-pay", 2000, "held"]
           ]

    # The legacy credit keeps its lot identity for restoration.
    assert [[lot_id]] =
             LegacyRepo.query!(
               "SELECT DISTINCT a.lot_id FROM room_allocations a WHERE a.source = 'credit'"
             ).rows

    assert lot_id != nil

    # A cancelled group settles its rooms and its lot gains entitlements.

    # The group's rooms are cancelled and its totals drop to zero.
    assert room_deposits("g-mig-cancelled") == [["room-a", "cancelled", 6000]]

    assert [cancelled] =
             LegacyRepo.query!(
               "SELECT lodging_total_cents, deposit_due_cents FROM groups WHERE group_id = 'g-mig-cancelled'"
             ).rows

    assert cancelled == [0, 0]

    # Converted cash keeps its disposition and links to the lot it created.
    assert allocations("g-mig-cancelled", "room-a") == [
             ["cash", nil, 1000, "converted"],
             ["cash", "op-mig-pay2", 2000, "converted"]
           ]

    assert Enum.uniq(converted_lot_ids("g-mig-cancelled")) == [op_mig_cancel_lot_id()]

    # The durable payment's entitlement is the telescoped bonus value of the
    # settled cash through it: BV(3000) - BV(1000) = 3300 - 1100.
    assert entitlements("op-mig-pay2") == [[op_mig_cancel_lot_id(), 2200]]

    # And the ledger keeps its shape: the converted cash is still converted.
    assert cash_buckets() == %{
             "held" => 6000,
             "refunded" => 0,
             "retained" => 0,
             "converted" => 3000
           }
  end

  # -- legacy data ------------------------------------------------------------

  defp insert_legacy_data do
    # An active group funded before durable operation records, plus one
    # durably recorded payment committed afterwards, and a legacy credit
    # lot applied to the group.
    active = insert_group("g-mig-active", "active", 60_000, 12_000)

    insert_room(active, "room-a", 10_000, 0)
    insert_room(active, "room-b", 10_000, 1)

    insert_legacy_payment(active, 4000, "held", "2026-10-04")
    insert_legacy_payment(active, 2000, "held", "2026-10-05")

    insert_durable_operation("op-mig-pay", "record_cash_payment", %{
      "status" => "applied",
      "group_id" => "g-mig-active",
      "amount_cents" => 2000,
      "outstanding_deposit_cents" => 10_000,
      "revision" => 3
    })

    lot = insert_legacy_lot("op-mig-old-cancel", 500, "2028-01-01")
    insert_legacy_credit_application(active, lot, 500, "applied")

    # A cancelled group whose refundable cancellation settled in hotel
    # credit, mixing pre-durable and durable payments into one lot.
    cancelled = insert_group("g-mig-cancelled", "cancelled", 30_000, 6000)

    insert_room(cancelled, "room-a", 10_000, 0)

    insert_legacy_payment(cancelled, 1000, "converted", "2026-10-04")
    insert_legacy_payment(cancelled, 2000, "converted", "2026-10-05")

    insert_durable_operation("op-mig-pay2", "record_cash_payment", %{
      "status" => "applied",
      "group_id" => "g-mig-cancelled",
      "amount_cents" => 2000,
      "outstanding_deposit_cents" => 4000,
      "revision" => 2
    })

    insert_durable_operation("op-mig-cancel", "cancel_group", %{
      "status" => "applied",
      "group_id" => "g-mig-cancelled",
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "credit_issued_cents" => 3300,
      "revision" => 3
    })

    insert_legacy_lot("op-mig-cancel", 3300, "2028-02-01")
  end

  defp insert_group(group_id, status, lodging, due) do
    LegacyRepo.query!(
      """
      INSERT INTO groups
        (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
         rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
         inserted_at, updated_at)
      VALUES (?, 'guest-22', 'ams-canal', '2026-10-03', '2027-03-10', '2027-03-13',
              'flexible', 'flex-14', ?, 3, ?, ?, ?, ?)
      """,
      [group_id, status, lodging, due, @now, @now]
    )

    [[id]] = LegacyRepo.query!("SELECT id FROM groups WHERE group_id = ?", [group_id]).rows
    id
  end

  defp insert_room(id, room_id, rate, position) do
    LegacyRepo.query!(
      """
      INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [id, room_id, rate, position, @now, @now]
    )
  end

  defp insert_legacy_payment(id, amount, state, recorded_on) do
    LegacyRepo.query!(
      """
      INSERT INTO payments (group_id, amount_cents, state, recorded_on, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [id, amount, state, recorded_on, @now, @now]
    )
  end

  defp insert_legacy_lot(source_operation_id, remaining, expires_on) do
    LegacyRepo.query!(
      """
      INSERT INTO credit_lots
        (guest_id, source_operation_id, remaining_cents, expires_on, inserted_at, updated_at)
      VALUES ('guest-22', ?, ?, ?, ?, ?)
      """,
      [source_operation_id, remaining, expires_on, @now, @now]
    )

    [[id]] =
      LegacyRepo.query!(
        "SELECT id FROM credit_lots WHERE source_operation_id = ? ORDER BY id DESC LIMIT 1",
        [source_operation_id]
      ).rows

    id
  end

  defp insert_legacy_credit_application(group_id, lot_id, amount, state) do
    LegacyRepo.query!(
      """
      INSERT INTO credit_applications (group_id, lot_id, amount_cents, state, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [group_id, lot_id, amount, state, @now, @now]
    )
  end

  defp insert_durable_operation(operation_id, type, result) do
    payload = Jason.encode!(%{"operation_id" => operation_id, "type" => type})

    LegacyRepo.query!(
      """
      INSERT INTO partner_operations (operation_id, type, payload, result, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [operation_id, type, payload, Jason.encode!(result), @now, @now]
    )
  end

  # -- post-migration reads -----------------------------------------------------

  defp payment_operation_ids(group_id) do
    LegacyRepo.query!(
      """
      SELECT p.operation_id, p.amount_cents FROM payments p
      JOIN groups g ON g.id = p.group_id
      WHERE g.group_id = ? ORDER BY p.id
      """,
      [group_id]
    ).rows
  end

  defp allocations(group_id, room_id) do
    LegacyRepo.query!(
      """
      SELECT a.source, a.operation_id, a.amount_cents, a.state FROM room_allocations a
      JOIN rooms r ON r.id = a.room_id
      JOIN groups g ON g.id = a.group_id
      WHERE g.group_id = ? AND r.room_id = ?
      ORDER BY a.id
      """,
      [group_id, room_id]
    ).rows
  end

  defp room_deposits(group_id) do
    LegacyRepo.query!(
      """
      SELECT r.room_id, r.status, r.deposit_due_cents FROM rooms r
      JOIN groups g ON g.id = r.group_id
      WHERE g.group_id = ? ORDER BY r.position
      """,
      [group_id]
    ).rows
  end

  defp funding_totals(group_id) do
    LegacyRepo.query!(
      """
      SELECT a.source, a.operation_id, SUM(a.amount_cents), MIN(a.state) FROM room_allocations a
      JOIN groups g ON g.id = a.group_id
      WHERE g.group_id = ?
      GROUP BY a.source, a.operation_id ORDER BY MIN(a.id)
      """,
      [group_id]
    ).rows
  end

  defp converted_lot_ids(group_id) do
    LegacyRepo.query!(
      """
      SELECT a.lot_id FROM room_allocations a
      JOIN groups g ON g.id = a.group_id
      WHERE g.group_id = ? AND a.source = 'cash' AND a.state = 'converted' AND a.lot_id IS NOT NULL
      ORDER BY a.id
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [lot_id] -> lot_id end)
  end

  defp op_mig_cancel_lot_id do
    [[id]] =
      LegacyRepo.query!("SELECT id FROM credit_lots WHERE source_operation_id = 'op-mig-cancel'").rows

    id
  end

  defp entitlements(payment_operation_id) do
    LegacyRepo.query!(
      """
      SELECT lot_id, entitlement_cents FROM credit_entitlements
      WHERE payment_operation_id = ? ORDER BY lot_id
      """,
      [payment_operation_id]
    ).rows
  end

  defp cash_buckets do
    buckets = %{"held" => 0, "refunded" => 0, "retained" => 0, "converted" => 0}

    LegacyRepo.query!("""
    SELECT a.state, SUM(a.amount_cents) FROM room_allocations a
    WHERE a.source = 'cash' GROUP BY a.state
    """).rows
    |> Map.new(fn [state, total] -> {state, total} end)
    |> Map.merge(buckets, fn _k, current, _default -> current end)
  end
end
