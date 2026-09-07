defmodule GroupStay.ReservationsPersistenceTest do
  # These tests use an isolated on-disk database and real transactions, because
  # sandbox ownership would serialize or wrap the transactions being exercised.
  use ExUnit.Case, async: false
  import Ecto.Query
  import GroupStay.OperationFixtures
  import Phoenix.ConnTest
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.Group

  @endpoint GroupStayWeb.Endpoint

  @migrations [
    {20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_907_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_907_000_002, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_907_000_003, GroupStay.Repo.Migrations.AddRoomAccounting},
    {20_260_907_000_004, GroupStay.Repo.Migrations.AddDepositTransfers},
    {20_260_907_000_005, GroupStay.Repo.Migrations.AddFinanceReporting},
    {20_260_907_000_006, GroupStay.Repo.Migrations.AddFinancePeriodClose}
  ]

  setup_all do
    for {version, module} <- @migrations, not Code.ensure_loaded?(module) do
      [path] = Path.wildcard(Path.join(Ecto.Migrator.migrations_path(Repo), "#{version}_*.exs"))
      Code.require_file(path)
    end

    :ok
  end

  setup context do
    directory =
      Path.expand("../../tmp/reservations-#{Ecto.UUID.generate()}", __DIR__)

    File.mkdir_p!(directory)
    database = Path.join(directory, "reservations.db")
    on_exit(fn -> remove_database(directory) end)

    start_repo(database, 1)

    migrations = Enum.take(@migrations, context[:migration_count] || length(@migrations))

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) ==
             Enum.map(migrations, &elem(&1, 0))

    stop_supervised!(Repo)
    repo = start_repo(database, 4)

    {:ok, database: database, repo: repo}
  end

  test "migrated records and finance settlements survive repository restart", %{
    database: database
  } do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_operation(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 123})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()
    stop_supervised!(Repo)
    start_repo(database, 1)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals

    assert totals == %{
             cash_held_cents: 123,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "competing conditional payments apply exactly once", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "concurrent exact retries have one effect and one durable record", %{repo: repo} do
    Reservations.process_batch([open_operation()])
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    results = concurrently(repo, fn _ -> payment end)

    assert [%{status: "applied", revision: 2}] = Enum.uniq(results)
    assert Reservations.get_group("group-81").cash_paid_cents == 100
    assert Repo.aggregate(Record, :count) == 2
    assert Operations.get_result(payment["operation_id"]) == hd(results)
  end

  test "concurrent conflicting submissions preserve the winning payload and result", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{"operation_id" => "same-id", "amount_cents" => index})
      end)

    assert [winner] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 7
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == winner.amount_cents
    record = Repo.get_by!(Record, operation_id: "same-id")
    assert record.payload["amount_cents"] == winner.amount_cents
    assert Operations.get_result("same-id") == winner
  end

  test "concurrent rejected retries commit one receipt", %{repo: repo} do
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    results = concurrently(repo, fn _ -> payment end)
    assert [%{code: "group_not_found"}] = Enum.uniq(results)
    assert Repo.aggregate(Record, :count) == 1
    Reservations.process_batch([open_operation()])
    assert Reservations.process_batch([payment]) == [hd(results)]
    assert Reservations.get_group("group-81").revision == 1
  end

  test "handled rejection discards domain writes but commits the rejection receipt" do
    Reservations.process_batch([open_operation()])
    attempt = operation("record_cash_payment", %{"amount_cents" => 100})
    before = Reservations.get_group("group-81")

    result =
      Operations.execute(attempt, fn _ ->
        Repo.update_all(Group, inc: [revision: 1, cash_paid_cents: 100])
        {:error, %{code: "invalid_amount"}}
      end)

    assert result.code == "invalid_amount"
    assert Reservations.get_group("group-81") == before
    assert Operations.get_result(attempt["operation_id"]) == result

    assert Operations.execute(attempt, fn _ -> flunk("retry evaluated domain state") end) ==
             result
  end

  test "receipt insertion failure returns HTTP 500, rolls back domain writes and aborts the batch" do
    opening = open_operation()

    payment =
      operation("record_cash_payment", %{"operation_id" => "fault", "amount_cents" => 500})

    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    operations = [opening, payment, cancellation]

    Repo.query!("""
    CREATE TRIGGER fail_receipt BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    """)

    assert_error_sent 500, fn ->
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    end

    assert Reservations.get_group("group-81").revision == 1
    assert Reservations.ledger().cash_held_cents == 0
    assert Operations.get_result(opening["operation_id"]).status == "applied"
    assert Operations.get_result("fault") == nil
    assert Operations.get_result(cancellation["operation_id"]) == nil

    Repo.query!("DROP TRIGGER fail_receipt")

    assert [%{revision: 1}, %{revision: 2}, %{revision: 3, credit_issued_cents: 550}] =
             Reservations.process_batch(operations)

    assert Repo.aggregate(Record, :count) == 3
    assert Reservations.ledger().cash_converted_to_credit_cents == 500
  end

  test "unexpected exception during settlement rolls back credit and remains retryable" do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 500})
    ])

    cancellation = operation("cancel_group", %{"refund_method" => "hotel_credit"})
    before = Reservations.get_group("group-81")

    Repo.query!("""
    CREATE TRIGGER fail_settlement BEFORE UPDATE ON groups
    WHEN NEW.status = 'cancelled'
    BEGIN SELECT RAISE(ABORT, 'injected settlement failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([cancellation]) end
    assert Reservations.get_group("group-81") == before
    assert Repo.all(GroupStay.Credits.Lot) == []
    assert Operations.get_result(cancellation["operation_id"]) == nil
    Repo.query!("DROP TRIGGER fail_settlement")
    assert [%{revision: 3, credit_issued_cents: 550}] = Reservations.process_batch([cancellation])
  end

  test "receipts preserve outcomes, payloads and commit order across repository restart", %{
    database: database
  } do
    operations = [
      operation("cancel_group", %{"operation_id" => "z", "expected_revision" => 1}),
      open_operation(%{"operation_id" => "a"}),
      operation("reschedule_group", %{"operation_id" => "m", "new_arrival_on" => "2027-03-01"}),
      operation("record_cash_payment", %{
        "operation_id" => "b",
        "amount_cents" => 1,
        "expected_revision" => 1
      })
    ]

    results = Reservations.process_batch(operations)
    records = Repo.all(from record in Record, order_by: record.id)
    group = Reservations.get_group("group-81")
    stop_supervised!(Repo)
    start_repo(database, 1)

    assert Reservations.process_batch(operations) == results
    assert Enum.map(operations, &Operations.get_result(&1["operation_id"])) == results
    assert Repo.all(from record in Record, order_by: record.id) == records
    assert Enum.map(records, & &1.payload) == operations
    assert Reservations.get_group("group-81") == group

    Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 5})])
    assert Repo.one(from record in Record, select: max(record.id)) > List.last(records).id
  end

  test "a fresh application process reads and retries receipts from the previous process", %{
    database: database
  } do
    stop_supervised!(Repo)

    operations = [
      open_operation(),
      operation("reschedule_group", %{"new_arrival_on" => "2027-03-01"}),
      operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    ]

    script = """
    Ecto.Adapters.SQL.Sandbox.mode(GroupStay.Repo, :auto)
    operations = Jason.decode!(System.fetch_env!("RESTART_TEST_OPERATIONS"))
    previous = Enum.map(operations, &GroupStay.Operations.get_result(&1["operation_id"]))
    results = GroupStay.Reservations.process_batch(operations)
    IO.puts("RESTART_RESULT=" <> Jason.encode!(%{previous: previous, results: results}))
    """

    run = fn ->
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", script],
          env: [
            {"MIX_ENV", "test"},
            {"GROUP_STAY_DATABASE_PATH", database},
            {"RESTART_TEST_OPERATIONS", Jason.encode!(operations)}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      [_, json] = Regex.run(~r/^RESTART_RESULT=(.+)$/m, output)
      Jason.decode!(json)
    end

    first = run.()
    assert first["previous"] == [nil, nil, nil]
    assert [%{"revision" => 1}, %{"revision" => 2}, %{"actual_revision" => 2}] = first["results"]
    second = run.()
    assert second["previous"] == first["results"]
    assert second["results"] == first["results"]
  end

  @tag migration_count: 2
  test "upgrading the previous release preserves domain records without inventing receipts" do
    {:ok, group} = GroupStay.Reservations.Booking.build(open_operation(), ~D[2026-10-03])
    group = %{group | revision: 2, deposit_paid_cents: 100, cash_paid_cents: 100}

    legacy =
      group
      |> Map.from_struct()
      |> Map.drop([:__meta__, :cash_reduced_cents, :cash_charged_back_cents])
      |> Map.update!(:rooms, fn rooms ->
        Jason.encode!(Enum.map(rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
      end)
      |> Map.new(fn {key, value} ->
        {key, if(is_struct(value, Date), do: Date.to_iso8601(value), else: value)}
      end)

    Repo.insert_all("groups", [legacy])

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, ?, ?, ?)",
      [group.guest_id, "previous-release", 550, "2027-10-04"]
    )

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert Repo.all(Record) == []
    migrated = Reservations.get_group(group.group_id)
    assert migrated.cash_paid_cents == group.cash_paid_cents
    assert migrated.revision == group.revision
    assert Enum.map(migrated.rooms, & &1.cash_paid_cents) == [100, 0]
    assert GroupStay.Credits.for_guest(group.guest_id, ~D[2026-10-04]).available_cents == 550
    assert Operations.get_result("previous-release") == nil

    payment = operation("record_cash_payment", %{"amount_cents" => 50, "expected_revision" => 2})
    assert [%{revision: 3} = result] = Reservations.process_batch([payment])
    assert Reservations.process_batch([payment]) == [result]
    assert Reservations.ledger().cash_held_cents == 150
  end

  test "competing unconditional payments do not lose cash or revision increments", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert Reservations.get_group("group-81").revision == 9
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "competing openings preserve group uniqueness", %{repo: repo} do
    results = concurrently(repo, &open_operation(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group-81").revision == 1
  end

  @tag :capture_log
  test "a writer outlasting the busy timeout does not lose or duplicate a payment", %{repo: repo} do
    Reservations.process_batch([open_operation()])
    parent = self()

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(
          fn ->
            send(parent, :write_lock_acquired)
            Process.sleep(2_200)
          end,
          mode: :immediate
        )
      end)

    assert_receive :write_lock_acquired, 1_000

    assert [%{status: "applied", revision: 2}] =
             Reservations.process_batch([
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
             ])

    assert {:ok, :ok} = Task.await(writer)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  @tag migration_count: 1
  test "upgrading the original schema backfills policies and preserves cash and settlements" do
    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 500, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 600, 0, 0},
          {"advance", "2026-10-01", "advance_purchase", "active", 700, 0, 0},
          {"cancelled", "2026-10-01", "flexible", "cancelled", 0, 200, 0},
          {"retained", "2026-10-01", "advance_purchase", "cancelled", 0, 0, 300}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-01', '2027-03-04', ?, ?, 3,
          '[{"room_id":"room-a","nightly_rate_cents":15000}]', 45000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active", do: 9000, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_001,
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    for {id, policy, cash} <- [
          {"old", "flex-14", 500},
          {"new", "flex-30", 600},
          {"advance", "advance-nonrefundable", 700},
          {"cancelled", "flex-14", 0}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.cash_paid_cents == cash
      assert group.deposit_paid_cents == cash
      assert group.credit_paid_cents == 0
      assert group.revision == 3
      assert Enum.map(group.rooms, & &1.room_id) == ["room-a"]
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 1800,
             cash_refunded_cents: 200,
             cash_retained_cents: 300,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{revision: 4, credit_issued_cents: 550}, %{refunded_cents: 0, retained_cents: 600}] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2027-02-01",
                 "refund_method" => "hotel_credit"
               }),
               operation("cancel_group", %{"group_id" => "new", "occurred_on" => "2027-02-01"})
             ])
  end

  test "credit lots and paused allocations survive repository restart", %{database: database} do
    Reservations.process_batch([
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 500}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_operation(),
      operation("apply_hotel_credit", %{"amount_cents" => 400})
    ])

    totals = Reservations.ledger(~D[2028-01-01])
    assert totals.credit_liability_cents == 400
    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.ledger(~D[2028-01-01]) == totals
    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 150

    assert [%{credit_issued_cents: 0, revision: 3}] =
             Reservations.process_batch([operation("cancel_group")])

    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 550
  end

  test "competing groups cannot spend the same guest credit twice", %{repo: repo} do
    Reservations.process_batch([
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 500}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    Reservations.process_batch(
      for index <- 1..8, do: open_operation(%{"group_id" => "target-#{index}"})
    )

    results =
      concurrently(repo, fn index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target-#{index}",
          "operation_id" => "credit-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 5
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 3
    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 50
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 550
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 500

    for {result, index} <- Enum.with_index(results, 1) do
      group = Reservations.get_group("target-#{index}")
      assert group.revision == if(result.status == "applied", do: 2, else: 1)
      assert group.credit_paid_cents == if(result.status == "applied", do: 100, else: 0)
    end
  end

  @tag migration_count: 3
  test "room upgrade puts legacy funding first and replays retained funding types in commit order" do
    legacy_group("mixed", 130, 130)

    Repo.query!(
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (1, 'guest-22', 'lot-z', 10, '2027-10-04'), (2, 'guest-22', 'lot-a', 20, '2027-10-04')"
    )

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('mixed', 1, 60), ('mixed', 2, 70)"
    )

    remember_legacy("credit-first", "apply_hotel_credit", "mixed", 90, "2026-11-01")
    remember_legacy("cash-second", "record_cash_payment", "mixed", 70, "2026-10-01")
    receipts = Repo.all(Record)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert Repo.all(Record) == receipts
    group = Reservations.get_group("mixed")
    assert {group.cash_paid_cents, group.credit_paid_cents, group.revision} == {130, 130, 4}

    assert Enum.map(group.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {60, 40},
             {10, 90},
             {60, 0}
           ]

    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 160
    assert {:error, "operation_not_found"} = GroupStay.Payments.statement("legacy")

    assert [%{refunded_cents: 10}] =
             Reservations.process_batch([
               operation("cancel_rooms", %{"group_id" => "mixed", "room_ids" => ["r2"]})
             ])

    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 120

    assert [%{amount_cents: 60}] =
             Reservations.process_batch([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "cash-second",
                 "amount_cents" => 60
               })
             ])

    assert {:ok, %{held_cents: 0, refunded_cents: 10, reduced_cents: 60}} =
             GroupStay.Payments.statement("cash-second")

    assert Reservations.get_group("mixed").cash_paid_cents == 60

    before_transfer = Reservations.ledger(~D[2026-10-04])

    Reservations.process_batch([
      open_operation(%{"group_id" => "destination"}),
      transfer_operation("mixed", "destination", 70)
    ])

    assert Reservations.get_group("mixed").cash_paid_cents == 30
    assert Reservations.get_group("mixed").credit_paid_cents == 0
    assert Reservations.get_group("destination").cash_paid_cents == 30
    assert Reservations.get_group("destination").credit_paid_cents == 40
    assert Reservations.ledger(~D[2026-10-04]) == before_transfer
    assert Repo.query!("SELECT * FROM transferred_payments").rows == []
  end

  @tag migration_count: 3
  test "upgrade preserves settled payment statements and senior rounded credit entitlement" do
    legacy_group("converted", 0, 0, "converted_to_credit", 10)
    legacy_group("target", 0, 8)
    legacy_group("refunded", 0, 0, "refunded", 100)
    legacy_group("retained", 0, 0, "retained", 100)
    remember_legacy("one", "record_cash_payment", "converted", 1)
    remember_legacy("five", "record_cash_payment", "converted", 5)
    remember_legacy("refund-pay", "record_cash_payment", "refunded", 100)
    remember_legacy("retain-pay", "record_cash_payment", "retained", 100)

    Repo.insert!(%Record{
      operation_id: "conversion",
      type: "cancel_group",
      payload: %{"type" => "cancel_group"},
      result: %{"status" => "applied", "group_id" => "converted", "credit_issued_cents" => 11}
    })

    Repo.query!(
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (1, 'guest-22', 'conversion', 3, '2027-10-04')"
    )

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('target', 1, 8)"
    )

    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    assert {:ok, %{converted_to_credit_cents: 1}} = GroupStay.Payments.statement("one")
    assert {:ok, %{refunded_cents: 100}} = GroupStay.Payments.statement("refund-pay")
    assert {:ok, %{retained_cents: 100}} = GroupStay.Payments.statement("retain-pay")
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 11

    assert [%{charged_back_cents: 1}] =
             Reservations.process_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "one"})
             ])

    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 1

    assert [%{charged_back_cents: 5}] =
             Reservations.process_batch([
               operation("charge_back_payment", %{"payment_operation_id" => "five"})
             ])

    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 4
    assert Reservations.get_group("target").revision == 4
  end

  test "concurrent reductions cannot overdraw a payment and chargebacks have one effect", %{
    repo: repo
  } do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 500})
    ])

    results =
      concurrently(repo, fn _ ->
        operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 100})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 5
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_not_reducible")) == 3
    assert {:ok, %{reduced_cents: 500, held_cents: 0}} = GroupStay.Payments.statement("p")

    Reservations.process_batch([
      operation("record_cash_payment", %{"operation_id" => "p2", "amount_cents" => 100})
    ])

    chargeback = operation("charge_back_payment", %{"payment_operation_id" => "p2"})
    results = concurrently(repo, fn _ -> chargeback end)
    assert [%{charged_back_cents: 100, revision: 9}] = Enum.uniq(results)
    assert Reservations.ledger().cash_charged_back_cents == 100
  end

  test "room settlements and corrections survive restart with their original receipts", %{
    database: database
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 10_000}),
      operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 100}),
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      operation("charge_back_payment", %{"payment_operation_id" => "p"})
    ]

    results = Reservations.process_batch(operations)
    assert Enum.all?(results, &(&1.status == "applied"))
    totals = Reservations.ledger(~D[2026-10-04])
    statement = GroupStay.Payments.statement("p")
    group = Reservations.get_group("group-81")
    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.process_batch(operations) == results
    assert Reservations.ledger(~D[2026-10-04]) == totals
    assert GroupStay.Payments.statement("p") == statement
    assert Reservations.get_group("group-81") == group
  end

  test "failed chargeback rolls back dispositions and revoked credit without storing a receipt" do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    before =
      {Reservations.get_group("group-81"), Reservations.ledger(~D[2026-10-04]),
       GroupStay.Payments.statement("p")}

    chargeback = operation("charge_back_payment", %{"payment_operation_id" => "p"})

    Repo.query!(
      "CREATE TRIGGER fail_chargeback BEFORE UPDATE ON groups WHEN NEW.cash_charged_back_cents > 0 BEGIN SELECT RAISE(ABORT, 'injected chargeback failure'); END"
    )

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([chargeback]) end
    assert Operations.get_result(chargeback["operation_id"]) == nil

    assert {Reservations.get_group("group-81"), Reservations.ledger(~D[2026-10-04]),
            GroupStay.Payments.statement("p")} == before

    Repo.query!("DROP TRIGGER fail_chargeback")
    assert [%{charged_back_cents: 100}] = Reservations.process_batch([chargeback])
  end

  test "concurrent exact transfers have one effect across both groups and survive restart", %{
    repo: repo,
    database: database
  } do
    Reservations.process_batch([
      open_operation(),
      open_operation(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100})
    ])

    transfer =
      transfer_operation("group-81", "destination", 100, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    results = concurrently(repo, fn _ -> transfer end)
    assert [result = %{source_revision: 3, destination_revision: 2}] = Enum.uniq(results)
    assert Reservations.get_group("group-81").deposit_paid_cents == 0
    assert Reservations.get_group("destination").deposit_paid_cents == 100
    assert Repo.aggregate(Record, :count) == 4

    assert {:ok, %{held_by_group: [%{group_id: "destination", amount_cents: 100}]}} =
             GroupStay.Payments.statement("p")

    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.process_batch([transfer]) == [result]
    assert Operations.get_result(transfer["operation_id"]) == result

    Reservations.process_batch([
      operation("charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.get_group("destination").revision == 3

    assert {:ok, %{held_by_group: [], charged_back_cents: 100}} =
             GroupStay.Payments.statement("p")

    stop_supervised!(Repo)
    start_repo(database, 1)
    assert {:ok, %{held_by_group: []}} = GroupStay.Payments.statement("p")
    assert Reservations.process_batch([transfer]) == [result]
  end

  test "competing transfers cannot overdraw the source", %{repo: repo} do
    Reservations.process_batch(
      [
        open_operation(),
        operation("record_cash_payment", %{"amount_cents" => 100})
      ] ++ for(index <- 1..8, do: open_operation(%{"group_id" => "destination-#{index}"}))
    )

    results =
      concurrently(repo, fn index ->
        transfer_operation("group-81", "destination-#{index}", 30)
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 3
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_held_funding")) == 5
    assert Reservations.get_group("group-81").deposit_paid_cents == 10
    assert Reservations.get_group("group-81").revision == 5
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "competing sources cannot overfill a destination", %{repo: repo} do
    Reservations.process_batch(
      [
        open_operation(%{"group_id" => "destination"}),
        operation("record_cash_payment", %{"group_id" => "destination", "amount_cents" => 19_400})
      ] ++
        Enum.flat_map(1..8, fn index ->
          [
            open_operation(%{"group_id" => "source-#{index}"}),
            operation("record_cash_payment", %{
              "group_id" => "source-#{index}",
              "amount_cents" => 50
            })
          ]
        end)
    )

    results =
      concurrently(repo, fn index -> transfer_operation("source-#{index}", "destination", 50) end)

    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_outstanding")) == 6
    assert Reservations.get_group("destination").deposit_paid_cents == 19_500
    assert Reservations.get_group("destination").revision == 4
    assert Reservations.ledger().cash_held_cents == 19_800
  end

  test "failure after both transfer views are written rolls back provenance and the sequence" do
    Reservations.process_batch([
      open_operation(),
      open_operation(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100})
    ])

    transfer = transfer_operation("group-81", "destination", 100, %{"operation_id" => "fault"})
    before = transfer_snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_transfer BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected transfer failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([transfer]) end
    assert transfer_snapshot() == before
    assert Operations.get_result("fault") == nil
    assert {:ok, statement} = GroupStay.Payments.statement("p")
    refute Map.has_key?(statement, :held_by_group)
    Repo.query!("DROP TRIGGER fail_transfer")

    assert [%{source_revision: 3, destination_revision: 2}] =
             Reservations.process_batch([transfer])
  end

  test "a correction failure rolls back every affected group" do
    Reservations.process_batch([
      open_operation(),
      open_operation(%{"group_id" => "z"}),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100}),
      transfer_operation("group-81", "z", 50)
    ])

    before = transfer_snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_other_group BEFORE UPDATE ON groups
    WHEN NEW.group_id = 'z'
    BEGIN SELECT RAISE(ABORT, 'injected correction failure'); END
    """)

    for type <- ["reduce_cash_payment", "charge_back_payment"] do
      attempt = operation(type, %{"payment_operation_id" => "p", "amount_cents" => 100})
      assert_raise Exqlite.Error, fn -> Reservations.process_batch([attempt]) end
      assert transfer_snapshot() == before
      assert Operations.get_result(attempt["operation_id"]) == nil
    end

    Repo.query!("DROP TRIGGER fail_other_group")
  end

  test "upgrading room accounting recovers mixed allocation order after settlements and corrections" do
    opening = fn id ->
      open_operation(%{
        "group_id" => id,
        "departure_on" => "2026-12-11",
        "rooms" =>
          for(index <- 1..3, do: %{"room_id" => "r#{index}", "nightly_rate_cents" => 500})
      })
    end

    Reservations.process_batch([
      opening.("seed"),
      operation("record_cash_payment", %{"group_id" => "seed", "amount_cents" => 200}),
      operation("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      opening.("source"),
      opening.("destination"),
      operation("record_cash_payment", %{
        "group_id" => "source",
        "operation_id" => "first",
        "amount_cents" => 30
      }),
      operation("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 100}),
      operation("record_cash_payment", %{
        "group_id" => "source",
        "operation_id" => "second",
        "amount_cents" => 100,
        "occurred_on" => "2026-10-01"
      }),
      operation("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 40}),
      operation("cancel_rooms", %{"group_id" => "source", "room_ids" => ["r1"]}),
      operation("reduce_cash_payment", %{"payment_operation_id" => "second", "amount_cents" => 20})
    ])

    groups = Repo.all(Group)
    totals = Reservations.ledger(~D[2026-10-04])
    receipts = Repo.all(Record)
    lots = Repo.all(GroupStay.Credits.Lot)

    # Remove reporting and transfer metadata to exercise the room-accounting upgrade.
    assert Ecto.Migrator.run(Repo, @migrations, :down, step: 3, log: false) == [
             20_260_907_000_006,
             20_260_907_000_005,
             20_260_907_000_004
           ]

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert Repo.all(Group) == groups
    assert Reservations.ledger(~D[2026-10-04]) == totals
    assert Repo.all(Record) == receipts
    assert Repo.all(GroupStay.Credits.Lot) == lots

    Reservations.process_batch([transfer_operation("source", "destination", 100)])

    assert Enum.map(
             Reservations.get_group("source").rooms,
             &{&1.cash_paid_cents, &1.credit_paid_cents}
           ) == [{0, 0}, {20, 30}, {0, 0}]

    assert Enum.map(
             Reservations.get_group("destination").rooms,
             &{&1.cash_paid_cents, &1.credit_paid_cents}
           ) == [{60, 40}, {0, 0}, {0, 0}]

    assert Reservations.ledger(~D[2026-10-04]) == totals
  end

  @tag migration_count: 5
  test "finance migration preserves legacy funding and starts from its current position" do
    {:ok, group} = GroupStay.Reservations.Booking.build(open_operation(), ~D[2026-10-03])
    group = Repo.insert!(group)
    GroupStay.Accounting.fund_cash(group, nil, 100)
    group = GroupStay.Accounting.refresh(group)

    Repo.insert!(%GroupStay.Credits.Lot{
      guest_id: "legacy-guest",
      source_operation_id: "legacy-credit",
      remaining_cents: 110,
      expires_on: ~D[2027-10-04]
    })

    totals = Reservations.ledger(~D[2026-10-04])

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert Reservations.get_group(group.group_id) == group
    assert Reservations.ledger(~D[2026-10-04]) == totals
    assert Repo.all(Record) == []
    assert {:error, "report_not_available"} = GroupStay.Finance.daily_report(~D[2026-10-04])

    Reservations.process_batch([
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    ])

    assert {:ok,
            %{
              cash: [%{opening_held_cents: 100, closing_held_cents: 100}],
              credit: %{opening_liability_cents: 110, closing_liability_cents: 110}
            }} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    assert Reservations.get_group(group.group_id) == group

    assert {:ok, %{credit: %{closing_liability_cents: 0}}} =
             GroupStay.Finance.daily_report(~D[2027-10-05])
  end

  test "finance inception and movements survive restart with exact concurrent retries", %{
    repo: repo,
    database: database
  } do
    Reservations.process_batch([open_operation()])
    inception = operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    results = concurrently(repo, fn _ -> inception end)
    assert [started] = Enum.uniq(results)

    assert started == %{
             operation_id: inception["operation_id"],
             status: "applied",
             starts_on: ~D[2026-10-04]
           }

    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    assert [%{status: "applied"}] = concurrently(repo, fn _ -> payment end) |> Enum.uniq()
    Reservations.process_batch([operation("cancel_group", %{"refund_method" => "hotel_credit"})])

    reports =
      for date <- [~D[2026-10-04], ~D[2027-10-05]], do: GroupStay.Finance.daily_report(date)

    assert [
             {:ok, %{credit: %{closing_liability_cents: 110}}},
             {:ok, %{credit: %{closing_liability_cents: 0}}}
           ] = reports

    movements = Repo.all(GroupStay.Finance.Movement)

    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.process_batch([inception]) == [started]
    assert [%{revision: 2}] = Reservations.process_batch([payment])

    assert for(date <- [~D[2026-10-04], ~D[2027-10-05]], do: GroupStay.Finance.daily_report(date)) ==
             reports

    assert Repo.all(GroupStay.Finance.Movement) == movements
    assert Repo.aggregate(GroupStay.Finance.Inception, :count) == 1
  end

  test "competing inception operations capture the opening position only once", %{repo: repo} do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results =
      concurrently(repo, fn index ->
        operation("start_finance_reporting", %{
          "operation_id" => "start-#{index}",
          "starts_on" => "2026-10-04"
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7

    assert {:ok, %{cash: [%{opening_held_cents: 100, closing_held_cents: 100}]}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    assert Repo.all(GroupStay.Finance.Movement) == []
  end

  test "finance and receipts roll back together, preserving earlier batch movements" do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    inception =
      operation("start_finance_reporting", %{
        "operation_id" => "fault",
        "starts_on" => "2026-10-04"
      })

    Repo.query!("""
    CREATE TRIGGER fail_finance_receipt BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([inception]) end
    assert Repo.all(GroupStay.Finance.Inception) == []
    assert Repo.all(GroupStay.Finance.Movement) == []
    assert Operations.get_result("fault") == nil
    Repo.query!("DROP TRIGGER fail_finance_receipt")
    assert [%{status: "applied"}] = Reservations.process_batch([inception])

    Reservations.process_batch([open_operation(%{"group_id" => "new"})])
    payment = operation("record_cash_payment", %{"group_id" => "new", "amount_cents" => 50})

    cancellation =
      operation("cancel_group", %{
        "group_id" => "new",
        "operation_id" => "fault-cancel",
        "refund_method" => "hotel_credit"
      })

    Repo.query!("""
    CREATE TRIGGER fail_finance_cancellation BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault-cancel'
    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([payment, cancellation]) end

    assert {:ok, %{cash: [%{closing_held_cents: 50}], credit: %{closing_liability_cents: 110}}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    assert Operations.get_result("fault-cancel") == nil
    assert Repo.aggregate(GroupStay.Credits.Lot, :count) == 1
    Repo.query!("DROP TRIGGER fail_finance_cancellation")
    Reservations.process_batch([payment, cancellation])

    assert {:ok, %{credit: %{closing_liability_cents: 165}}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])
  end

  test "a failed journal write rolls back financial state and stays retryable" do
    Reservations.process_batch([
      open_operation(),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    ])

    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    Repo.query!("""
    CREATE TRIGGER fail_journal BEFORE INSERT ON finance_movements
    BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([payment]) end
    assert Reservations.get_group("group-81").revision == 1
    assert Reservations.ledger().cash_held_cents == 0
    assert Repo.all(GroupStay.Finance.Movement) == []
    assert Operations.get_result(payment["operation_id"]) == nil
    Repo.query!("DROP TRIGGER fail_journal")
    assert [%{status: "applied"}] = Reservations.process_batch([payment])
  end

  @tag migration_count: 6
  test "period-close migration preserves the existing journal as ordinary movements" do
    {:ok, group} = GroupStay.Reservations.Booking.build(open_operation(), ~D[2026-10-03])
    group = Repo.insert!(group)
    GroupStay.Accounting.fund_cash(group, nil, 100)
    group = GroupStay.Accounting.refresh(group)

    Repo.insert!(%GroupStay.Credits.Lot{
      guest_id: "guest-22",
      source_operation_id: "legacy-credit",
      remaining_cents: 110,
      expires_on: ~D[2027-10-04]
    })

    Repo.query!("""
    INSERT INTO finance_inception (id, starts_on, cash, credit_liability_cents)
    VALUES (1, '2026-10-04', '{}', 110)
    """)

    Repo.query!("""
    INSERT INTO finance_movements (operation_id, posting_on, property_id, category, amount_cents)
    VALUES ('legacy-payment', '2026-10-04', 'ams-canal', 'received_cents', 100),
           ('legacy-start', '2027-10-05', NULL, 'expired_cents', 110)
    """)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_006
           ]

    assert Reservations.get_group(group.group_id) == group
    assert Enum.all?(Repo.all(GroupStay.Finance.Movement), &(&1.late_adjustment == false))

    assert {:ok, %{cash: [%{movements: %{"received_cents" => 100}, closing_held_cents: 100}]}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    Reservations.process_batch([
      operation("close_finance_period", %{"period_end_on" => "2027-10-05"})
    ])

    published = GroupStay.Finance.daily_report(~D[2027-10-05])
    assert {:ok, %{status: "closed", credit: %{movements: %{"expired_cents" => 110}}}} = published
    Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 25})])
    assert GroupStay.Finance.daily_report(~D[2027-10-05]) == published

    assert {:ok,
            %{
              cash: [%{closing_held_cents: 125}],
              late_adjustments: %{cash: [%{movements: %{"received_cents" => 25}}]}
            }} =
             GroupStay.Finance.daily_report(~D[2027-10-06])
  end

  test "concurrent close retries and competing cutoffs remain durable across restart", %{
    repo: repo,
    database: database
  } do
    Reservations.process_batch([
      open_operation(),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"}),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    close = operation("close_finance_period", %{"period_end_on" => "2026-10-04"})
    assert [result] = concurrently(repo, fn _ -> close end) |> Enum.uniq()

    assert result == %{
             operation_id: close["operation_id"],
             status: "applied",
             period_end_on: ~D[2026-10-04]
           }

    results =
      concurrently(repo, fn index ->
        operation("close_finance_period", %{
          "operation_id" => "close-#{index}",
          "period_end_on" => "2027-10-05"
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 7

    reports =
      for date <- [~D[2026-10-04], ~D[2027-10-05]], do: GroupStay.Finance.daily_report(date)

    assert Enum.all?(reports, fn {:ok, report} -> report.status == "closed" end)
    assert Repo.aggregate(GroupStay.Finance.PeriodClose, :count) == 2

    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.process_batch([close]) == [result]
    assert Operations.get_result(close["operation_id"]) == result

    Reservations.process_batch([
      open_operation(%{"group_id" => "new"}),
      operation("apply_hotel_credit", %{"group_id" => "new", "amount_cents" => 100}),
      operation("close_finance_period", %{"period_end_on" => "2027-10-06"})
    ])

    assert for(date <- [~D[2026-10-04], ~D[2027-10-05]], do: GroupStay.Finance.daily_report(date)) ==
             reports

    assert {:ok,
            %{
              status: "closed",
              credit: %{closing_liability_cents: 100},
              late_adjustments: %{credit: %{"expired_cents" => -100}}
            }} =
             GroupStay.Finance.daily_report(~D[2027-10-06])
  end

  test "a close racing payments publishes exactly the payments committed before it", %{repo: repo} do
    Reservations.process_batch([
      open_operation(),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    ])

    results =
      concurrently(repo, fn
        1 -> operation("close_finance_period", %{"period_end_on" => "2026-10-04"})
        _ -> operation("record_cash_payment", %{"amount_cents" => 1})
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    close_record = Repo.get_by!(Record, type: "close_finance_period")

    before_close =
      Repo.aggregate(
        from(r in Record, where: r.type == "record_cash_payment" and r.id < ^close_record.id),
        :count
      )

    {:ok, published} = GroupStay.Finance.daily_report(~D[2026-10-04])
    assert published.status == "closed"
    assert Enum.sum(Enum.map(published.cash, & &1.closing_held_cents)) == before_close
    {:ok, open_report} = GroupStay.Finance.daily_report(~D[2026-10-05])
    assert [%{opening_held_cents: ^before_close, closing_held_cents: 7}] = open_report.cash

    assert Enum.sum(Enum.map(open_report.late_adjustments.cash, & &1.movements["received_cents"])) ==
             7 - before_close

    Reservations.process_batch([operation("record_cash_payment", %{"amount_cents" => 1})])
    assert GroupStay.Finance.daily_report(~D[2026-10-04]) == {:ok, published}
  end

  test "failed close receipt rolls back publication and leaves later batch operations unprocessed" do
    Reservations.process_batch([
      open_operation(),
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
    ])

    payment = operation("record_cash_payment", %{"amount_cents" => 100})

    close =
      operation("close_finance_period", %{
        "operation_id" => "fault-close",
        "period_end_on" => "2026-10-04"
      })

    later = operation("record_cash_payment", %{"amount_cents" => 50})

    Repo.query!("""
    CREATE TRIGGER fail_close_receipt BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault-close'
    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.process_batch([payment, close, later]) end
    assert Repo.all(GroupStay.Finance.PeriodClose) == []
    assert Operations.get_result("fault-close") == nil
    assert Operations.get_result(later["operation_id"]) == nil

    assert {:ok, %{status: "open", cash: [%{closing_held_cents: 100}]}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    Repo.query!("DROP TRIGGER fail_close_receipt")

    assert [%{status: "applied"}, %{status: "applied"}, %{status: "applied"}] =
             Reservations.process_batch([payment, close, later])

    assert {:ok, %{status: "closed", cash: [%{closing_held_cents: 100}]}} =
             GroupStay.Finance.daily_report(~D[2026-10-04])

    assert {:ok,
            %{
              cash: [%{closing_held_cents: 150}],
              late_adjustments: %{cash: [%{movements: %{"received_cents" => 50}}]}
            }} =
             GroupStay.Finance.daily_report(~D[2026-10-05])
  end

  defp transfer_operation(source, destination, amount, overrides \\ %{}) do
    operation(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        overrides
      )
    )
    |> Map.delete("group_id")
  end

  defp transfer_snapshot do
    Enum.map(
      [
        Group,
        GroupStay.Accounting.CashAllocation,
        GroupStay.Credits.Allocation,
        GroupStay.Credits.Lot,
        GroupStay.Accounting.CreditEntitlement
      ],
      &Repo.all/1
    ) ++
      [
        Repo.query!("SELECT * FROM allocation_sequence").rows,
        Repo.query!("SELECT * FROM transferred_payments ORDER BY payment_operation_id").rows
      ]
  end

  defp legacy_group(id, cash, credit, disposition \\ nil, settled \\ 0) do
    rooms = for index <- 1..3, do: %{"room_id" => "r#{index}", "nightly_rate_cents" => 500}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
        policy_version, cash_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents)
      VALUES (?, 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-11', 'flexible', ?, 4, ?, 1500, ?, ?, 'flex-14', ?, ?, ?, ?, ?)
      """,
      [
        id,
        if(disposition, do: "cancelled", else: "active"),
        Jason.encode!(rooms),
        if(disposition, do: 0, else: 300),
        cash + credit,
        cash,
        credit,
        if(disposition == "refunded", do: settled, else: 0),
        if(disposition == "retained", do: settled, else: 0),
        if(disposition == "converted_to_credit", do: settled, else: 0)
      ]
    )
  end

  defp remember_legacy(id, type, group, amount, date \\ "2026-10-04") do
    Repo.insert!(%Record{
      operation_id: id,
      type: type,
      payload: %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      },
      result: %{
        "operation_id" => id,
        "status" => "applied",
        "group_id" => group,
        "amount_cents" => amount,
        "revision" => 4,
        "outstanding_deposit_cents" => 0
      }
    })
  end

  defp start_repo(database, pool_size) do
    # These tests deliberately queue eight writers behind SQLite's write lock.
    # Allow the pool queue to outlast busy-timeout retries on slower machines.
    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: database,
         pool: DBConnection.ConnectionPool,
         pool_size: pool_size,
         queue_target: 10_000,
         queue_interval: 10_000}
      )

    Repo.put_dynamic_repo(repo)
    repo
  end

  defp remove_database(directory, retries_left \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries_left > 0 ->
        # Native SQLite cleanup can briefly change WAL files during teardown.
        Process.sleep(20)
        remove_database(directory, retries_left - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrently(repo, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              [result] = Reservations.process_batch([build_operation.(index)])
              result
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end
end
