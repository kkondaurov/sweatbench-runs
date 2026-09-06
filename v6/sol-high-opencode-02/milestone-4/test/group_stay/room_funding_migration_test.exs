defmodule GroupStay.RoomFundingMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :group_stay,
      adapter: Ecto.Adapters.SQLite3
  end

  test "backfills the senior legacy block before durable funding without moving credit balances" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group-stay-migration-#{System.unique_integer([:positive])}.db"
      )

    Application.put_env(:group_stay, MigrationRepo,
      database: database,
      pool_size: 1,
      pool: DBConnection.ConnectionPool
    )

    start_supervised!(MigrationRepo)

    on_exit(fn ->
      Application.delete_env(:group_stay, MigrationRepo)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end)

    migrations = Path.expand("../../priv/repo/migrations", __DIR__)

    Ecto.Migrator.run(MigrationRepo, migrations, :up,
      to: 20_260_829_020_000,
      log: false
    )

    insert_prior_release_state()

    assert Ecto.Migrator.run(MigrationRepo, migrations, :up, all: true, log: false) == [
             20_260_829_030_000
           ]

    assert rows("""
           SELECT room_id, lodging_total_cents, deposit_due_cents,
                  cash_paid_cents, credit_paid_cents
           FROM rooms
           WHERE group_id = 'group-1'
           ORDER BY position
           """) == [
             ["room-a", 500, 100, 60, 40],
             ["room-b", 500, 100, 90, 10],
             ["room-c", 500, 100, 0, 50]
           ]

    assert rows("""
           SELECT payment_operation_id, funding_order, recorded_cents
           FROM cash_sources
           WHERE group_id = 'group-1'
           ORDER BY funding_order
           """) == [[nil, 0, 50], ["pay-durable", 1, 100]]

    assert rows("""
           SELECT r.room_id, a.funding_operation_id, a.credit_lot_id, a.amount_cents
           FROM credit_allocations a
           JOIN rooms r ON r.id = a.room_id
           ORDER BY a.id
           """) == [
             ["room-a", nil, 1, 40],
             ["room-b", "credit-durable", 1, 10],
             ["room-c", "credit-durable", 1, 20],
             ["room-c", "credit-durable", 2, 30]
           ]

    assert rows("SELECT id, remaining_cents FROM credit_lots ORDER BY id") == [[1, 7], [2, 9]]

    assert rows("""
           SELECT status, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
                  cash_paid_cents
           FROM groups
           WHERE group_id = 'cancelled-group'
           """) == [["cancelled", 0, 0, 0, 0]]

    assert rows("""
           SELECT payment_operation_id, recorded_cents, retained_cents
           FROM cash_sources
           WHERE group_id = 'cancelled-group'
           ORDER BY funding_order
           """) == [[nil, 20, 20], ["pay-cancelled", 30, 30]]

    assert rows("""
           SELECT status, lodging_total_cents, deposit_due_cents,
                  cash_paid_cents, credit_paid_cents
           FROM rooms
           WHERE group_id = 'cancelled-group'
           """) == [["cancelled", 500, 100, 0, 0]]
  end

  defp insert_prior_release_state do
    query!("""
    INSERT INTO groups
      (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
       rate_plan, policy_version, status, lodging_total_cents, deposit_due_cents,
       deposit_paid_cents, cash_paid_cents, credit_paid_cents, refunded_cents,
       retained_cents, cash_converted_to_credit_cents, revision)
    VALUES
      ('group-1', 'guest-1', 'ams-canal', '2026-10-01', '2026-12-20', '2026-12-21',
       'flexible', 'flex-14', 'active', 1500, 300, 250, 150, 100, 0, 0, 0, 5)
    """)

    Enum.with_index(["room-a", "room-b", "room-c"])
    |> Enum.each(fn {room_id, position} ->
      query!(
        "INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position) VALUES (?, ?, 500, ?)",
        ["group-1", room_id, position]
      )
    end)

    query!("""
    INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on)
    VALUES ('guest-1', 'issue-1', 7, '2027-12-31'),
           ('guest-1', 'issue-2', 9, '2027-12-31')
    """)

    query!("""
    INSERT INTO credit_allocations (credit_lot_id, group_id, amount_cents)
    VALUES (1, 'group-1', 70), (2, 'group-1', 30)
    """)

    insert_operation(
      "pay-durable",
      "record_cash_payment",
      %{
        "operation_id" => "pay-durable",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "pay-durable",
        "status" => "applied",
        "group_id" => "group-1",
        "amount_cents" => 100,
        "outstanding_deposit_cents" => 150,
        "revision" => 4
      }
    )

    insert_operation(
      "credit-durable",
      "apply_hotel_credit",
      %{
        "operation_id" => "credit-durable",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-02",
        "group_id" => "group-1",
        "amount_cents" => 60
      },
      %{
        "operation_id" => "credit-durable",
        "status" => "applied",
        "group_id" => "group-1",
        "amount_cents" => 60,
        "outstanding_deposit_cents" => 50,
        "revision" => 5
      }
    )

    query!("""
    INSERT INTO groups
      (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
       rate_plan, policy_version, status, lodging_total_cents, deposit_due_cents,
       deposit_paid_cents, cash_paid_cents, credit_paid_cents, refunded_cents,
       retained_cents, cash_converted_to_credit_cents, revision)
    VALUES
      ('cancelled-group', 'guest-2', 'ams-canal', '2026-10-01',
       '2026-12-20', '2026-12-21', 'flexible', 'flex-14', 'cancelled',
       500, 100, 50, 50, 0, 0, 50, 0, 3)
    """)

    query!("""
    INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position)
    VALUES ('cancelled-group', 'cancelled-room', 500, 0)
    """)

    insert_operation(
      "pay-cancelled",
      "record_cash_payment",
      %{
        "operation_id" => "pay-cancelled",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "cancelled-group",
        "amount_cents" => 30
      },
      %{
        "operation_id" => "pay-cancelled",
        "status" => "applied",
        "group_id" => "cancelled-group",
        "amount_cents" => 30,
        "outstanding_deposit_cents" => 50,
        "revision" => 2
      }
    )
  end

  defp insert_operation(operation_id, type, submission, result) do
    query!(
      """
      INSERT INTO partner_operations
        (operation_id, operation_type, submission, result, inserted_at)
      VALUES (?, ?, ?, ?, '2026-10-03T00:00:00.000000')
      """,
      [operation_id, type, Jason.encode!(submission), Jason.encode!(result)]
    )
  end

  defp rows(sql), do: query!(sql).rows
  defp query!(sql, params \\ []), do: MigrationRepo.query!(sql, params, log: false)
end
