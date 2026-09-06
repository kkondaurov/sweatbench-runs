defmodule GroupStay.MigrationUpgradeRepo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end

defmodule GroupStay.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias GroupStay.MigrationUpgradeRepo

  @old_version 20_260_825_000_000
  @durable_version 20_260_825_020_000
  @room_accounting_version 20_260_825_030_000

  setup do
    previous = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)
    on_exit(fn -> Code.compiler_options(ignore_module_conflict: previous) end)
    :ok
  end

  test "upgrades populated operational-core databases and backfills immutable policy and cash" do
    database =
      Path.join(File.cwd!(), "migration_upgrade_#{System.unique_integer([:positive])}.db")

    Application.put_env(:group_stay, MigrationUpgradeRepo,
      database: database,
      pool_size: 1,
      log: false
    )

    on_exit(fn ->
      Application.delete_env(:group_stay, MigrationUpgradeRepo)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end)

    start_supervised!(MigrationUpgradeRepo)
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, to: @old_version)

    insert_legacy_group("old-flex", "2026-12-31", "flexible", 125)
    insert_legacy_group("new-flex", "2027-01-01", "flexible", 250)
    insert_legacy_group("advance", "2027-01-01", "advance_purchase", 375)

    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, all: true)

    rows =
      Ecto.Adapters.SQL.query!(
        MigrationUpgradeRepo,
        """
        SELECT group_id, policy_version, deposit_paid_cents, cash_paid_cents,
               credit_paid_cents, cash_converted_to_credit_cents
          FROM groups
         ORDER BY group_id
        """,
        []
      ).rows

    assert rows == [
             ["advance", "advance-nonrefundable", 375, 375, 0, 0],
             ["new-flex", "flex-30", 250, 250, 0, 0],
             ["old-flex", "flex-14", 125, 125, 0, 0]
           ]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT COUNT(*) FROM partner_operations",
             []
           ).rows == [[0]]
  end

  test "backfills legacy funding ahead of durable funding without changing balances" do
    start_upgrade_database("room_accounting")
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, to: @durable_version)

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, lodging_total_cents,
        deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
        cash_held_cents, cash_refunded_cents, cash_retained_cents,
        cash_converted_to_credit_cents
      ) VALUES (
        'funded', 'legacy-guest', 'legacy-property', '2027-01-01', '2027-04-01',
        '2027-04-02', 'flexible', 'flex-30', 'active', 5, 1000, 200, 200,
        130, 70, 130, 0, 0, 0
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      "INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position) VALUES ('funded', 'room-a', 500, 0), ('funded', 'room-b', 500, 1)",
      []
    )

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('legacy-guest', 'legacy-lot', 30, '2028-01-01')",
      []
    )

    lot_id =
      Ecto.Adapters.SQL.query!(MigrationUpgradeRepo, "SELECT id FROM credit_lots", []).rows
      |> hd()
      |> hd()

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('funded', ?, 30), ('funded', ?, 40)",
      [lot_id, lot_id]
    )

    insert_durable_funding("durable-credit", "apply_hotel_credit", 50)
    insert_durable_funding("durable-payment", "record_cash_payment", 90)

    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, all: true)

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT room_id, status, lodging_total_cents, deposit_due_cents, cash_paid_cents, credit_paid_cents FROM rooms ORDER BY position",
             []
           ).rows == [
             ["room-a", "active", 500, 100, 40, 60],
             ["room-b", "active", 500, 100, 90, 10]
           ]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT rooms.room_id, cash_allocations.payment_operation_id, cash_allocations.amount_cents FROM cash_allocations JOIN rooms ON rooms.id = cash_allocations.room_id ORDER BY cash_allocations.id",
             []
           ).rows == [
             ["room-a", nil, 40],
             ["room-b", "durable-payment", 90]
           ]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents FROM cash_payments WHERE payment_operation_id = 'durable-payment'",
             []
           ).rows == [[90, 90, 0, 0, 0]]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT cash_held_cents, credit_paid_cents, deposit_paid_cents FROM groups WHERE group_id = 'funded'",
             []
           ).rows == [[130, 70, 200]]

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             """
             SELECT kind, room_id, source, amount_cents, allocation_order
               FROM (
                 SELECT 'cash' AS kind, rooms.room_id, cash_allocations.payment_operation_id AS source,
                        cash_allocations.amount_cents, cash_allocations.allocation_order
                   FROM cash_allocations
                   JOIN rooms ON rooms.id = cash_allocations.room_id
                 UNION ALL
                 SELECT 'credit', rooms.room_id, CAST(credit_allocations.credit_lot_id AS TEXT),
                        credit_allocations.amount_cents, credit_allocations.allocation_order
                   FROM credit_allocations
                   JOIN rooms ON rooms.id = credit_allocations.room_id
               )
              ORDER BY allocation_order
             """,
             []
           ).rows == [
             ["cash", "room-a", nil, 40, 1],
             ["credit", "room-a", Integer.to_string(lot_id), 20, 2],
             ["credit", "room-a", Integer.to_string(lot_id), 10, 3],
             ["credit", "room-a", Integer.to_string(lot_id), 30, 4],
             ["credit", "room-b", Integer.to_string(lot_id), 10, 5],
             ["cash", "room-b", "durable-payment", 90, 6]
           ]
  end

  test "backfills payment settlement provenance for later transferred chargebacks" do
    start_upgrade_database("cash_dispositions")
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)

    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, to: @room_accounting_version)

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, lodging_total_cents,
        deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
        cash_held_cents, cash_refunded_cents, cash_retained_cents,
        cash_converted_to_credit_cents, cash_reduced_cents, cash_charged_back_cents
      ) VALUES (
        'settled', 'legacy-guest', 'legacy-property', '2027-01-01', '2027-04-01',
        '2027-04-02', 'flexible', 'flex-30', 'cancelled', 3, 0, 0, 0,
        0, 0, 0, 40, 30, 30, 0, 0
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      """
      INSERT INTO cash_payments (
        payment_operation_id, group_id, recorded_cents, held_cents, refunded_cents,
        retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents
      ) VALUES ('settled-payment', 'settled', 100, 0, 40, 30, 30, 0, 0)
      """,
      []
    )

    Ecto.Migrator.run(MigrationUpgradeRepo, migrations, :up, all: true)

    assert Ecto.Adapters.SQL.query!(
             MigrationUpgradeRepo,
             "SELECT group_id, kind, amount_cents FROM cash_dispositions ORDER BY kind",
             []
           ).rows == [
             ["settled", "converted_to_credit", 30],
             ["settled", "refunded", 40],
             ["settled", "retained", 30]
           ]
  end

  defp insert_legacy_group(group_id, booked_on, rate_plan, paid) do
    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_held_cents
      ) VALUES (?, 'legacy-guest', 'legacy-property', ?, '2027-04-01', '2027-04-02',
                ?, 'active', 2, 1000, 500, ?, ?)
      """,
      [group_id, booked_on, rate_plan, paid, paid]
    )
  end

  defp start_upgrade_database(label) do
    database =
      Path.join(
        File.cwd!(),
        "migration_upgrade_#{label}_#{System.unique_integer([:positive])}.db"
      )

    Application.put_env(:group_stay, MigrationUpgradeRepo,
      database: database,
      pool_size: 1,
      log: false
    )

    on_exit(fn ->
      Application.delete_env(:group_stay, MigrationUpgradeRepo)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end)

    start_supervised!(MigrationUpgradeRepo)
    database
  end

  defp insert_durable_funding(operation_id, type, amount) do
    payload =
      Jason.encode!(%{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2027-01-02",
        "group_id" => "funded",
        "amount_cents" => amount
      })

    result =
      Jason.encode!(%{
        "operation_id" => operation_id,
        "status" => "applied",
        "group_id" => "funded",
        "amount_cents" => amount,
        "outstanding_deposit_cents" => 0,
        "revision" => 4
      })

    Ecto.Adapters.SQL.query!(
      MigrationUpgradeRepo,
      "INSERT INTO partner_operations (operation_id, operation_type, submitted_payload, result, inserted_at) VALUES (?, ?, ?, ?, ?)",
      [operation_id, type, payload, result, DateTime.utc_now()]
    )
  end
end
