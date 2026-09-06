defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo,
      otp_app: :group_stay,
      adapter: Ecto.Adapters.SQLite3
  end

  test "upgrades existing groups with fixed policies and cash funding intact" do
    purge_migration_modules()

    Application.put_env(:group_stay, LegacyRepo,
      database: ":memory:",
      pool_size: 1,
      priv: "priv/legacy_repo"
    )

    on_exit(fn -> Application.delete_env(:group_stay, LegacyRepo) end)

    start_supervised!(LegacyRepo)
    migrations_path = Application.app_dir(:group_stay, "priv/repo/migrations")

    assert [20_260_828_000_000] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, to: 20_260_828_000_000)

    insert_legacy_group("old-flex", "2026-12-31", "flexible", 700)
    insert_legacy_group("new-flex", "2027-01-01", "flexible", 800)
    insert_legacy_group("advance", "2026-01-01", "advance_purchase", 900)

    assert [
             20_260_828_010_000,
             20_260_828_020_000,
             20_260_828_030_000,
             20_260_828_040_000,
             20_260_828_050_000
           ] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, all: true)

    result =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        """
        SELECT group_id, policy_version, cash_paid_cents, credit_paid_cents
        FROM groups
        ORDER BY group_id
        """,
        []
      )

    assert result.rows == [
             ["advance", "advance-nonrefundable", 900, 0],
             ["new-flex", "flex-30", 800, 0],
             ["old-flex", "flex-14", 700, 0]
           ]

    assert Ecto.Adapters.SQL.query!(LegacyRepo, "SELECT COUNT(*) FROM operations", []).rows == [
             [0]
           ]
  end

  test "backfills senior legacy funding before durable funding in commit order" do
    purge_migration_modules()

    Application.put_env(:group_stay, LegacyRepo,
      database: ":memory:",
      pool_size: 1,
      priv: "priv/legacy_repo"
    )

    on_exit(fn -> Application.delete_env(:group_stay, LegacyRepo) end)

    start_supervised!(LegacyRepo)
    migrations_path = Application.app_dir(:group_stay, "priv/repo/migrations")

    assert [20_260_828_000_000, 20_260_828_010_000, 20_260_828_020_000] =
             Ecto.Migrator.run(
               LegacyRepo,
               migrations_path,
               :up,
               to: 20_260_828_020_000
             )

    rooms =
      Jason.encode!(%{
        "items" => [
          %{"room_id" => "first", "nightly_rate_cents" => 25_000},
          %{"room_id" => "second", "nightly_rate_cents" => 25_000}
        ]
      })

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, rooms, lodging_total_cents,
        deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
        cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents,
        revision, inserted_at, updated_at
      ) VALUES (
        'funded', 'guest', 'property', '2026-01-01', '2027-06-01', '2027-06-02',
        'flexible', 'flex-14', 'active', ?, 50000, 10000, 9000, 6000, 3000,
        0, 0, 0, 3, '2026-08-28 00:00:00', '2026-08-28 00:00:00'
      )
      """,
      [rooms]
    )

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO credit_lots (
        guest_id, source_operation_id, remaining_cents, expires_on, inserted_at, updated_at
      ) VALUES ('guest', 'legacy-credit', 3300, '2027-12-31',
                '2026-08-28 00:00:00', '2026-08-28 00:00:00')
      """,
      []
    )

    [[lot_id]] =
      Ecto.Adapters.SQL.query!(LegacyRepo, "SELECT id FROM credit_lots", []).rows

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO credit_allocations (
        credit_lot_id, group_id, amount_cents, inserted_at, updated_at
      ) VALUES (?, 'funded', 3000, '2026-08-28 00:00:00', '2026-08-28 00:00:00')
      """,
      [lot_id]
    )

    insert_operation(
      "durable-cash",
      "record_cash_payment",
      %{"group_id" => "funded", "amount_cents" => 2_000}
    )

    insert_operation(
      "durable-credit",
      "apply_hotel_credit",
      %{"group_id" => "funded", "amount_cents" => 2_000}
    )

    assert [20_260_828_030_000, 20_260_828_040_000, 20_260_828_050_000] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, all: true)

    assert Ecto.Adapters.SQL.query!(
             LegacyRepo,
             """
             SELECT room_id, funding_type, payment_operation_id, credit_lot_id, amount_cents
             FROM room_fundings
             ORDER BY id
             """,
             []
           ).rows == [
             ["first", "cash", nil, nil, 4_000],
             ["first", "credit", nil, lot_id, 1_000],
             ["second", "cash", "durable-cash", nil, 2_000],
             ["second", "credit", nil, lot_id, 2_000]
           ]

    assert Ecto.Adapters.SQL.query!(
             LegacyRepo,
             """
             SELECT recorded_cents, held_cents, refunded_cents, retained_cents,
                    converted_to_credit_cents, reduced_cents, charged_back_cents
             FROM payment_dispositions
             WHERE payment_operation_id = 'durable-cash'
             """,
             []
           ).rows == [[2_000, 2_000, 0, 0, 0, 0, 0]]

    [[stored_rooms]] =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        "SELECT rooms FROM groups WHERE group_id = 'funded'",
        []
      ).rows

    assert %{"items" => [%{"deposit_due_cents" => 5_000}, %{"deposit_due_cents" => 5_000}]} =
             Jason.decode!(stored_rooms)
  end

  test "backfills settlement attribution for existing payment dispositions" do
    purge_migration_modules()

    Application.put_env(:group_stay, LegacyRepo,
      database: ":memory:",
      pool_size: 1,
      priv: "priv/legacy_repo"
    )

    on_exit(fn -> Application.delete_env(:group_stay, LegacyRepo) end)

    start_supervised!(LegacyRepo)
    migrations_path = Application.app_dir(:group_stay, "priv/repo/migrations")

    assert [
             20_260_828_000_000,
             20_260_828_010_000,
             20_260_828_020_000,
             20_260_828_030_000
           ] = Ecto.Migrator.run(LegacyRepo, migrations_path, :up, to: 20_260_828_030_000)

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO payment_dispositions (
        payment_operation_id, original_group_id, recorded_cents, held_cents,
        refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents,
        charged_back_cents, inserted_at, updated_at
      ) VALUES (
        'settled-payment', 'settled-group', 1000, 100, 200, 300, 400, 0, 0,
        '2026-08-28 00:00:00.000000', '2026-08-28 00:00:00.000000'
      )
      """,
      []
    )

    assert [20_260_828_040_000, 20_260_828_050_000] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, all: true)

    assert Ecto.Adapters.SQL.query!(
             LegacyRepo,
             """
             SELECT payment_operation_id, group_id, disposition, amount_cents
             FROM payment_settlements
             ORDER BY disposition
             """,
             []
           ).rows == [
             ["settled-payment", "settled-group", "converted_to_credit", 400],
             ["settled-payment", "settled-group", "refunded", 200],
             ["settled-payment", "settled-group", "retained", 300]
           ]

    assert Ecto.Adapters.SQL.query!(
             LegacyRepo,
             """
             SELECT transfer_participated
             FROM payment_dispositions
             WHERE payment_operation_id = 'settled-payment'
             """,
             []
           ).rows == [[0]]
  end

  defp insert_legacy_group(group_id, booked_on, rate_plan, paid_cents) do
    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_refunded_cents, cash_retained_cents, revision,
        inserted_at, updated_at
      ) VALUES (?, 'guest', 'property', ?, '2027-06-01', '2027-06-02', ?, 'active',
                '{}', 1000, 1000, ?, 0, 0, 1, '2026-08-28 00:00:00',
                '2026-08-28 00:00:00')
      """,
      [group_id, booked_on, rate_plan, paid_cents]
    )
  end

  defp insert_operation(operation_id, operation_type, result) do
    submitted = %{
      "operation_id" => operation_id,
      "type" => operation_type,
      "group_id" => result["group_id"],
      "amount_cents" => result["amount_cents"]
    }

    stored_result =
      Map.merge(result, %{"operation_id" => operation_id, "status" => "applied", "revision" => 2})

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO operations (
        operation_id, operation_type, submitted_content, result, inserted_at
      ) VALUES (?, ?, ?, ?, '2026-08-28 00:00:00.000000')
      """,
      [operation_id, operation_type, Jason.encode!(submitted), Jason.encode!(stored_result)]
    )
  end

  defp purge_migration_modules do
    for module <- [
          GroupStay.Repo.Migrations.CreateGroups,
          GroupStay.Repo.Migrations.AddCancellationEconomics,
          GroupStay.Repo.Migrations.CreateOperations,
          GroupStay.Repo.Migrations.AddRoomAndPaymentAccounting,
          GroupStay.Repo.Migrations.AddDepositTransfers,
          GroupStay.Repo.Migrations.AddDailyFinanceReporting
        ] do
      :code.purge(module)
      :code.delete(module)
    end
  end
end
