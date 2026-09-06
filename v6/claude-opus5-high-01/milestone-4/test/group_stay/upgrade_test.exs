defmodule GroupStay.UpgradeTest do
  @moduledoc """
  A database written by an earlier release must come forward by running the
  migrations from this one.

  The interesting part is funding that predates durable operation records: it has
  no payment identity, so it is carried forward as one unattributed senior block
  per group that fills rooms before anything a record can account for.
  """

  use ExUnit.Case, async: false

  alias GroupStay.MigrationRepo

  @migrations Path.expand("../../priv/repo/migrations", __DIR__)
  @durable_operations_release 20_260_301_000_000

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "group_stay_upgrade_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({MigrationRepo, database: path, pool_size: 1, log: false})

    on_exit(fn ->
      for suffix <- ["", "-shm", "-wal"], do: File.rm(path <> suffix)
    end)

    # The migrations were already compiled to migrate the test database; loading
    # them again here is the point of the test, not a mistake.
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, false) end)

    migrate(to: @durable_operations_release)

    build_earlier_release()
  end

  describe "upgrading a database written before rooms were funded individually" do
    defp build_earlier_release do
      # An active group funded partly before durable records existed: 12_000 of
      # cash and 3000 of credit, of which only a 2000 payment has a record.
      funded = open_group("group-funded", cash_paid: 12_000, credit_paid: 3000)
      room_a = add_room(funded, "room-a", 15_000, 9000, 0)
      room_b = add_room(funded, "room-b", 17_500, 10_500, 1)

      lot_one = add_lot("cancel-1", 1800, "2028-01-01")
      lot_two = add_lot("cancel-2", 1200, "2028-02-01")
      add_redemption(lot_one, funded, 1800)
      add_redemption(lot_two, funded, 1200)

      add_operation("pay-new", "record_cash_payment", %{
        "operation_id" => "pay-new",
        "status" => "applied",
        "group_id" => "group-funded",
        "amount_cents" => 2000,
        "outstanding_deposit_cents" => 4500,
        "revision" => 5
      })

      # A group that was already cancelled and whose cash the hotel retained.
      settled = open_group("group-settled", cash_paid: 5000, status: "cancelled", retained: 5000)
      room_c = add_room(settled, "room-c", 15_000, 9000, 0)
      add_room(settled, "room-d", 17_500, 10_500, 1)

      migrate(all: true)

      {:ok,
       rooms: %{a: room_a, b: room_b, c: room_c},
       lots: %{one: lot_one, two: lot_two},
       groups: %{funded: funded, settled: settled}}
    end

    test "fills rooms with the senior block first, then the recorded payment", context do
      %{rooms: rooms, lots: lots} = context

      assert allocations(context.groups.funded) == [
               [rooms.a, "cash", nil, nil, 9000, "held"],
               [rooms.b, "cash", nil, nil, 1000, "held"],
               [rooms.b, "credit", nil, lots.one, 1800, "held"],
               [rooms.b, "credit", nil, lots.two, 1200, "held"],
               [rooms.b, "cash", "pay-new", nil, 2000, "held"]
             ]
    end

    test "leaves every aggregate balance where it was", _context do
      assert sum("SELECT SUM(amount_cents) FROM room_allocations WHERE kind = 'cash'") == 17_000
      assert sum("SELECT SUM(amount_cents) FROM room_allocations WHERE kind = 'credit'") == 3000

      assert sum(
               "SELECT SUM(amount_cents) FROM room_allocations WHERE kind = 'cash' AND disposition = 'held'"
             ) == 12_000

      assert sum(
               "SELECT SUM(amount_cents) FROM room_allocations WHERE kind = 'cash' AND disposition = 'retained'"
             ) == 5000

      assert sum("SELECT SUM(unrecovered_clawback_cents) FROM credit_lots") == 0
    end

    test "settles a group that was already cancelled and cancels its rooms", context do
      assert allocations(context.groups.settled) == [
               [context.rooms.c, "cash", nil, nil, 5000, "retained"]
             ]

      assert query("SELECT status FROM rooms WHERE group_ref = ?1", [context.groups.settled]) ==
               [["cancelled"], ["cancelled"]]

      assert query("SELECT status FROM rooms WHERE group_ref = ?1", [context.groups.funded]) ==
               [["active"], ["active"]]
    end

    test "drops the group-level settlement columns it folded in", _context do
      assert_raise Exqlite.Error, fn ->
        query("SELECT cash_retained_cents FROM groups")
      end
    end
  end

  defp migrate(opts) do
    Ecto.Migrator.run(MigrationRepo, @migrations, :up, Keyword.put(opts, :log, false))
  end

  # --- writing the earlier shape ------------------------------------------

  defp open_group(group_id, opts) do
    insert!(
      """
      INSERT INTO groups
        (group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
         policy_version, status, revision, lodging_total_cents, deposit_due_cents,
         deposit_paid_cents, cash_paid_cents, credit_paid_cents, cash_refunded_cents,
         cash_retained_cents, cash_converted_to_credit_cents, inserted_at, updated_at)
      VALUES (?1, 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-13', 'flexible',
              'flex-14', ?2, 5, 97500, 19500, ?3, ?4, ?5, 0, ?6, 0, ?7, ?7)
      """,
      [
        group_id,
        Keyword.get(opts, :status, "active"),
        Keyword.get(opts, :cash_paid, 0) + Keyword.get(opts, :credit_paid, 0),
        Keyword.get(opts, :cash_paid, 0),
        Keyword.get(opts, :credit_paid, 0),
        Keyword.get(opts, :retained, 0),
        now()
      ]
    )
  end

  defp add_room(group_ref, room_id, nightly_rate_cents, deposit_cents, position) do
    insert!(
      """
      INSERT INTO rooms
        (group_ref, room_id, nightly_rate_cents, lodging_cents, deposit_cents, position,
         inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
      """,
      [
        group_ref,
        room_id,
        nightly_rate_cents,
        nightly_rate_cents * 3,
        deposit_cents,
        position,
        now()
      ]
    )
  end

  defp add_lot(source_operation_id, issued_cents, expires_on) do
    insert!(
      """
      INSERT INTO credit_lots
        (guest_id, source_operation_id, issued_cents, remaining_cents, expires_on,
         inserted_at, updated_at)
      VALUES ('guest-22', ?1, ?2, 0, ?3, ?4, ?4)
      """,
      [source_operation_id, issued_cents, expires_on, now()]
    )
  end

  defp add_redemption(lot_ref, group_ref, amount_cents) do
    insert!(
      """
      INSERT INTO credit_redemptions (lot_ref, group_ref, amount_cents, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?4)
      """,
      [lot_ref, group_ref, amount_cents, now()]
    )
  end

  defp add_operation(operation_id, type, result) do
    insert!(
      """
      INSERT INTO operations (operation_id, type, request_payload, result, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?5)
      """,
      [
        operation_id,
        type,
        Jason.encode!(%{"operation_id" => operation_id}),
        Jason.encode!(result),
        now()
      ]
    )
  end

  # --- reading the upgraded shape -----------------------------------------

  defp allocations(group_ref) do
    query(
      """
      SELECT room_ref, kind, operation_id, lot_ref, amount_cents, disposition
        FROM room_allocations
       WHERE group_ref = ?1
       ORDER BY id
      """,
      [group_ref]
    )
  end

  defp sum(sql) do
    [[total]] = query(sql)
    total || 0
  end

  defp query(sql, params \\ []), do: MigrationRepo.query!(sql, params).rows

  defp insert!(sql, params) do
    MigrationRepo.query!(sql, params)
    [[id]] = query("SELECT last_insert_rowid()")
    id
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
