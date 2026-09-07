defmodule GroupStay.Reservations.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn
  alias GroupStay.{FinanceReporting, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Inception, Movement}

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    Room,
    RoomAllocation
  }

  @endpoint GroupStayWeb.Endpoint

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup_all do
    migrations =
      Repo.config()[:priv]
      |> then(fn priv -> Path.join(priv || "priv/repo", "migrations/*.exs") end)
      |> Path.wildcard()
      |> Enum.map(fn path ->
        {version, _name} = path |> Path.basename() |> Integer.parse()

        module =
          Module.concat(
            GroupStay.Repo.Migrations,
            path
            |> Path.basename(".exs")
            |> String.split("_", parts: 2)
            |> List.last()
            |> Macro.camelize()
          )

        unless Code.ensure_loaded?(module), do: Code.require_file(path)
        {version, module}
      end)

    %{migrations: migrations}
  end

  setup %{tmp_dir: directory, migrations: migrations} = tags do
    # A real pool and an isolated file exercise SQLite locking and durability outside
    # the SQL sandbox. ExUnit's temporary directory stays within this repository.
    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      # Keep contention waits shorter than the pool queue and test deadlines; the
      # production retry path still arbitrates independent SQLite connections.
      busy_timeout: Map.get(tags, :busy_timeout, 100)
    ]

    # Initialize WAL and migrate with one connection before starting concurrent writers.
    # Multiple connections racing to initialize an empty SQLite file can report SQLITE_BUSY.
    initializer = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(initializer)

    initial_migrations =
      Enum.take(migrations, Map.get(tags, :migration_count, length(migrations)))

    Ecto.Migrator.run(Repo, initial_migrations, :up, all: true, log: false)
    stop_supervised!(Repo)

    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    %{repository: repository, options: options}
  end

  test "concurrent expected revisions allow exactly one writer", %{repository: repository} do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 2
    assert group.deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional concurrent payments do not lose cash or revisions", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 9
    assert group.deposit_paid_cents == 800
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "concurrent opens reserve a group identifier only once", %{repository: repository} do
    results = concurrently(repository, &open_group(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Repo.aggregate(GroupStay.Reservations.Room, :count) == 2
  end

  test "migrations are repeatable and balances survive repository restart", %{
    options: options,
    migrations: migrations
  } do
    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group")
    ])

    before = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger() == ledger

    assert ledger == %{
             cash_held_cents: 0,
             cash_refunded_cents: 100,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag migration_count: 1
  test "upgrades original databases using booked dates without changing existing accounting", %{
    migrations: migrations
  } do
    for {id, booked_on, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2027-01-01", "advance_purchase", "active", 300, 0, 0},
          {"cancelled", "2027-01-01", "flexible", "cancelled", 0, 400, 0},
          {"retained", "2026-12-31", "advance_purchase", "cancelled", 0, 0, 500}
        ] do
      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
           status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
           cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'legacy-guest', 'legacy-property', ?, '2028-03-01', '2028-03-04', ?, ?, 7,
                15000, ?, ?, ?, ?)
        """,
        [
          id,
          booked_on,
          plan,
          status,
          if(status == "active", do: 3000, else: 0),
          paid,
          refunded,
          retained
        ]
      )

      Repo.query!(
        """
        INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents)
        VALUES (?, 'legacy-room', 0, 5000)
        """,
        [id]
      )
    end

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_907_000_001,
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"},
          {"cancelled", "flex-30"},
          {"retained", "advance-nonrefundable"}
        ] do
      assert {:ok, group} = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.credit_paid_cents == 0
      assert group.cash_converted_to_credit_cents == 0
      assert [%{room_id: "legacy-room", nightly_rate_cents: 5000}] = group.rooms
      assert GroupStayWeb.GroupJSON.data(group).cash_paid_cents == group.deposit_paid_cents
    end

    assert Reservations.ledger(~D[2028-01-01]) == %{
             cash_held_cents: 600,
             cash_refunded_cents: 400,
             cash_retained_cents: 500,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    [moved, cancelled] =
      Reservations.submit_batch([
        operation("reschedule_group", %{
          "group_id" => "old",
          "new_arrival_on" => "2028-04-01",
          "occurred_on" => "2027-02-01",
          "expected_revision" => 7
        }),
        operation("cancel_group", %{
          "group_id" => "old",
          "occurred_on" => "2028-03-18",
          "expected_revision" => 8
        })
      ])

    assert moved.policy_version == "flex-14"
    assert moved.refundable_until == "2028-03-18"
    assert cancelled.refunded_cents == 100
    assert cancelled.revision == 9
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
  end

  test "concurrent groups cannot spend the same guest credit twice", %{repository: repository} do
    issue_credit()

    Reservations.submit_batch(
      for index <- 1..8, do: open_group(%{"group_id" => "target-#{index}"})
    )

    results =
      concurrently(repository, fn index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target-#{index}",
          "amount_cents" => 110,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 110
    assert Repo.aggregate(GroupStay.Reservations.CreditAllocation, :sum, :amount_cents) == 110

    for result <- results do
      if result.status == "applied", do: assert(result.revision == 2)
    end
  end

  test "concurrent credit applications check revision before consuming lots", %{
    repository: repository
  } do
    issue_credit()
    Reservations.submit_batch([open_group(%{"group_id" => "target"})])

    results =
      concurrently(repository, fn _index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target",
          "amount_cents" => 10,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 100
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  test "credit provenance, policy and settlements survive restart", %{options: options} do
    issue_credit()

    Reservations.submit_batch([
      open_group(%{
        "group_id" => "target",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      }),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    before = Reservations.get_group("target")
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert Reservations.get_group("target") == before
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 80
    assert Reservations.ledger(~D[2027-11-02]).cash_converted_to_credit_cents == 100
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 30

    [result] =
      Reservations.submit_batch([
        operation("cancel_group", %{
          "group_id" => "target",
          "occurred_on" => "2027-01-01",
          "expected_revision" => 2
        })
      ])

    assert result.status == "applied"
    assert result.credit_issued_cents == 0

    assert [
             %{
               source_operation_id: "cancel_group-1",
               remaining_cents: 110,
               expires_on: ~D[2027-11-01]
             }
           ] =
             Reservations.guest_credit("guest-22", ~D[2027-01-01]).lots
  end

  @tag busy_timeout: 25
  test "retries initial write-lock contention without replaying a payment", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])
    parent = self()

    lock_holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(repository)

        Repo.transaction(
          fn ->
            send(parent, :locked)
            receive do: (:release -> :ok)
          end,
          mode: :immediate
        )
      end)

    assert_receive :locked

    # Hold the lock beyond the first SQLite busy timeout, then let the retry acquire it.
    ExUnit.CaptureLog.capture_log(fn ->
      Process.send_after(lock_holder.pid, :release, 60)

      assert [%{status: "applied", revision: 2}] =
               Reservations.submit_batch([
                 operation("record_cash_payment", %{
                   "amount_cents" => 100,
                   "expected_revision" => 1
                 })
               ])

      assert {:ok, :ok} = Task.await(lock_holder)
    end)

    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.deposit_paid_cents == 100
    assert group.revision == 2
  end

  test "database failures after BEGIN roll back writes and are not retried" do
    parent = self()

    assert_raise Exqlite.Error, fn ->
      Repo.with_write_lock(fn ->
        send(parent, :executed)

        Repo.insert!(%GroupStay.Reservations.CreditLot{
          guest_id: "guest-22",
          source_operation_id: "failed",
          expires_on: ~D[2027-01-01],
          remaining_cents: 10
        })

        Repo.query!("UPDATE credit_lots SET nonexistent_column = 1")
      end)
    end

    assert_receive :executed
    refute_receive :executed
    assert Repo.all(GroupStay.Reservations.CreditLot) == []
  end

  test "concurrent exact retries have one payment and return the same revision", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])
    payment = operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
    results = concurrently(repository, fn _ -> payment end)

    assert [result] = Enum.uniq(results)
    assert result.status == "applied"
    assert result.revision == 2
    assert Repo.get!(Group, "group-81").deposit_paid_cents == 100
    assert Repo.get!(Group, "group-81").revision == 2
    assert Repo.aggregate(OperationRecord, :count) == 2
    assert Reservations.get_operation(payment["operation_id"]) == {:ok, result}
  end

  test "concurrent identifier conflicts preserve the winning submission", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])
    payment = operation("record_cash_payment")
    results = concurrently(repository, fn index -> Map.put(payment, "amount_cents", index) end)
    assert [applied] = Enum.filter(results, &(&1.status == "applied"))
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 7
    assert Repo.get!(Group, "group-81").deposit_paid_cents == applied.amount_cents
    assert Repo.get!(Group, "group-81").revision == 2
    record = Repo.get_by!(OperationRecord, operation_id: payment["operation_id"])
    assert record.payload == Map.put(payment, "amount_cents", applied.amount_cents)
    assert Reservations.get_operation(payment["operation_id"]) == {:ok, applied}
  end

  test "concurrent rejected retries share one durable record", %{repository: repository} do
    missing = operation("cancel_group")
    results = concurrently(repository, fn _ -> missing end)
    assert [%{code: "group_not_found"} = rejected] = Enum.uniq(results)
    assert Repo.aggregate(OperationRecord, :count) == 1
    Reservations.submit_batch([open_group()])
    assert Reservations.submit_batch([missing]) == [rejected]
    assert Repo.get!(Group, "group-81").revision == 1
  end

  test "audit records and original applied and rejected results survive repository restart", %{
    options: options
  } do
    missing = operation("cancel_group")
    open = open_group()
    stale = operation("cancel_group", %{"expected_revision" => 7})
    move = operation("reschedule_group", %{"new_arrival_on" => "2028-01-01"})
    operations = [missing, open, stale, move]
    results = Reservations.submit_batch(operations)
    before = operation_snapshot()

    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)

    assert Reservations.submit_batch(operations) == results
    assert operation_snapshot() == before

    for {operation, result} <- Enum.zip(operations, results) do
      assert Reservations.get_operation(operation["operation_id"]) == {:ok, result}
    end

    records = Repo.all(from record in OperationRecord, order_by: record.id)
    assert Enum.map(records, & &1.payload) == operations

    [next] =
      Reservations.submit_batch([operation("record_cash_payment", %{"amount_cents" => 10})])

    assert Repo.get_by!(OperationRecord, operation_id: next.operation_id).id >
             List.last(records).id

    # A replay needs only the audit table, even if the domain tables cannot be read.
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert Reservations.submit_batch(operations) == results

    for {operation, result} <- Enum.zip(operations, results) do
      assert Reservations.get_operation(operation["operation_id"]) == {:ok, result}
    end
  end

  @tag migration_count: 2
  test "upgrades the credit release without changing groups, lots or allocations", %{
    migrations: migrations
  } do
    # Historical fixtures use the historical columns, not today's Ecto schemas.
    Repo.query!("""
    INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
      rate_plan, policy_version, revision, lodging_total_cents, deposit_due_cents,
      deposit_paid_cents, credit_paid_cents)
    VALUES ('group-81', 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-13',
      'flexible', 'flex-14', 3, 97500, 19500, 100, 80)
    """)

    Repo.query!(
      "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES ('group-81', 'room-b', 0, 15000), ('group-81', 'room-a', 1, 17500)"
    )

    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest-22', 'legacy-cancellation', 30, '2027-11-01')"
    )

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) SELECT 'group-81', id, 80 FROM credit_lots"
    )

    before =
      Map.new(["groups", "rooms", "credit_lots", "credit_allocations"], fn table ->
        {table, Repo.query!("SELECT * FROM " <> table)}
      end)

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_907_000_002,
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    assert Repo.all(OperationRecord) == []

    for {table, result} <- before do
      assert Repo.query!("SELECT " <> Enum.join(result.columns, ", ") <> " FROM " <> table).rows ==
               result.rows
    end

    assert {:ok, migrated} = Reservations.get_group("group-81")

    assert [
             %{cash_paid_cents: 20, credit_paid_cents: 80},
             %{cash_paid_cents: 0, credit_paid_cents: 0}
           ] = migrated.rooms

    payment = operation("record_cash_payment", %{"amount_cents" => 10, "expected_revision" => 3})
    assert [%{status: "applied", revision: 4} = result] = Reservations.submit_batch([payment])
    assert Reservations.submit_batch([payment]) == [result]
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  test "a fresh application process reads and replays original results", %{
    options: options,
    tmp_dir: directory
  } do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "cold-payment", "amount_cents" => 100}),
      open_group(%{"group_id" => "destination"}),
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "destination",
        "amount_cents" => 50,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "cold-payment",
        "amount_cents" => 30
      }),
      operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
      operation("charge_back_payment", %{"payment_operation_id" => "cold-payment"}),
      operation("reschedule_group", %{"new_arrival_on" => "2028-01-01"}),
      operation("cancel_group", %{"expected_revision" => 1}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ]

    results = operations |> Reservations.submit_batch() |> Jason.encode!() |> Jason.decode!()
    before = operation_snapshot()
    input_path = Path.join(directory, "operations.json")
    output_path = Path.join(directory, "replayed.json")
    File.write!(input_path, Jason.encode!(operations))
    stop_supervised!(Repo)

    {output, status} =
      System.cmd("mix", ["run", "test/support/replay_operations.exs", input_path, output_path],
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", options[:database]},
          {"PHX_SERVER", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert output_path |> File.read!() |> Jason.decode!() == %{
             "stored_results" => results,
             "replayed_results" => results
           }

    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert operation_snapshot() == before
  end

  test "an audit write failure returns 500, rolls back settlement, and aborts the remaining batch" do
    issue_credit()

    Reservations.submit_batch([
      open_group(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 50})
    ])

    # Fail only after settlement has restored credit, removed allocations, issued a
    # bonus lot and updated the group. All of those writes must roll back together.
    Repo.query!("""
    CREATE TRIGGER fail_operation_record BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    first = operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 10})

    fault =
      operation("cancel_group", %{
        "group_id" => "target",
        "operation_id" => "fault",
        "refund_method" => "hotel_credit"
      })

    last = open_group(%{"group_id" => "after-fault"})
    before = operation_snapshot()

    assert {500, _headers, body} =
             assert_error_sent(500, fn ->
               build_conn()
               |> put_req_header("content-type", "application/json")
               |> post(
                 "/api/v1/partner-batches",
                 Jason.encode!(%{"operations" => [first, fault, last]})
               )
             end)

    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}

    assert Reservations.get_operation("fault") == {:error, "operation_not_found"}
    assert Reservations.get_operation(last["operation_id"]) == {:error, "operation_not_found"}
    assert Reservations.get_group("after-fault") == {:error, "group_not_found"}
    assert {:ok, paid} = Reservations.get_operation(first["operation_id"])
    assert paid.revision == 4
    group = Repo.get!(Group, "target")
    assert group.status == :active
    assert group.revision == 4
    assert group.deposit_paid_cents == 140
    assert group.credit_paid_cents == 80
    after_failure = operation_snapshot()

    for schema <- [Room, CreditLot, CreditAllocation] do
      assert after_failure[schema] == before[schema]
    end

    Repo.query!("DROP TRIGGER fail_operation_record")
    assert [^paid, cancelled, opened] = Reservations.submit_batch([first, fault, last])
    assert cancelled.revision == 5
    assert cancelled.credit_issued_cents == 66
    assert opened.status == "applied"
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 176
  end

  @tag migration_count: 3
  test "migration allocates the legacy senior block before recorded funding in commit order", %{
    migrations: migrations,
    options: options
  } do
    legacy_group("mixed", "active", 175, 60)
    late = legacy_lot("late", "2028-12-01", 20)
    early = legacy_lot("early", "2028-01-01", 50)

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('mixed', ?, 20), ('mixed', ?, 40)",
      [late, early]
    )

    records = [
      legacy_record("credit-first", "apply_hotel_credit", "mixed", 30, "2026-11-01"),
      legacy_record("z-payment", "record_cash_payment", "mixed", 60, "2027-01-01"),
      legacy_record("credit-second", "apply_hotel_credit", "mixed", 10, "2026-12-01"),
      legacy_record("a-payment", "record_cash_payment", "mixed", 30, "2026-01-01")
    ]

    audit = Repo.query!("SELECT * FROM operation_records ORDER BY id").rows

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_907_000_003,
             20_260_907_000_004,
             20_260_907_000_005
           ]

    assert Repo.query!("SELECT * FROM operation_records ORDER BY id").rows == audit
    assert {:ok, group} = Reservations.get_group("mixed")
    assert group.deposit_paid_cents == 175
    assert group.credit_paid_cents == 60

    assert Enum.map(group.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) == [
             {25, 25},
             {25, 25},
             {40, 10},
             {25, 0}
           ]

    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 130
    assert {:ok, %{held_cents: 60, recorded_cents: 60}} = Reservations.get_payment("z-payment")
    assert {:error, "operation_not_found"} = Reservations.get_payment("legacy-payment")

    [reduced, cancelled] =
      Reservations.submit_batch([
        operation("reduce_cash_payment", %{
          "payment_operation_id" => "z-payment",
          "amount_cents" => 40,
          "expected_revision" => 7
        }),
        operation("cancel_rooms", %{
          "group_id" => "mixed",
          "room_ids" => ["r1"],
          "expected_revision" => 8
        })
      ])

    assert reduced.revision == 8
    assert reduced.group_id == "mixed"
    assert reduced.outstanding_deposit_cents == 65
    assert cancelled.refunded_cents == 25
    assert cancelled.revision == 9
    assert {:ok, %{held_cents: 20, reduced_cents: 40}} = Reservations.get_payment("z-payment")
    assert Repo.get!(CreditLot, late).remaining_cents == 40
    assert Repo.get!(CreditLot, early).remaining_cents == 55

    assert Enum.map(Reservations.submit_batch(records), & &1.status) ==
             List.duplicate("applied", 4)

    before = operation_snapshot()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert operation_snapshot() == before
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
  end

  @tag migration_count: 3
  test "migration cannot fund an earlier operation from a lot issued later", %{
    migrations: migrations
  } do
    legacy_group("target", "active", 80, 60)
    legacy_group("source", "cancelled", 0, 0, 30)
    late = legacy_lot("legacy-lot", "2028-11-01", 10)
    early = legacy_lot("later-issuance", "2027-11-01", 3)

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('target', ?, 30), ('target', ?, 30)",
      [late, early]
    )

    legacy_record("first-credit", "apply_hotel_credit", "target", 30, "2026-11-01")
    legacy_record("middle-cash", "record_cash_payment", "target", 20, "2026-11-01")

    cancellation =
      operation("cancel_group", %{
        "operation_id" => "later-issuance",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      })

    insert_legacy_record(cancellation, %{
      operation_id: "later-issuance",
      status: "applied",
      group_id: "source",
      revision: 7,
      refunded_cents: 0,
      retained_cents: 0,
      credit_issued_cents: 33
    })

    legacy_record("later-credit", "apply_hotel_credit", "target", 30, "2026-11-01")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert [%{refunded_cents: 20}] =
             Reservations.submit_batch([
               operation("cancel_rooms", %{"group_id" => "target", "room_ids" => ["r1"]})
             ])

    assert Repo.get!(CreditLot, late).remaining_cents == 40
    assert Repo.get!(CreditLot, early).remaining_cents == 3
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 73
  end

  @tag migration_count: 3
  test "migration reconstructs settled payment statements and senior credit entitlements", %{
    migrations: migrations
  } do
    legacy_group("converted", "cancelled", 0, 0, 10)
    legacy_group("refunded", "cancelled", 0, 0, 0, 20)
    legacy_group("retained", "cancelled", 0, 0, 0, 0, 30)
    payment = legacy_record("converted-pay", "record_cash_payment", "converted", 5, "2026-11-01")
    legacy_record("refunded-pay", "record_cash_payment", "refunded", 20, "2026-11-01")
    legacy_record("retained-pay", "record_cash_payment", "retained", 30, "2026-11-01")

    cancellation =
      operation("cancel_group", %{
        "operation_id" => "converted-cancel",
        "group_id" => "converted",
        "refund_method" => "hotel_credit"
      })

    result = %{
      operation_id: "converted-cancel",
      status: "applied",
      group_id: "converted",
      revision: 7,
      refunded_cents: 0,
      retained_cents: 0,
      credit_issued_cents: 11
    }

    insert_legacy_record(cancellation, result)
    lot = legacy_lot("converted-cancel", "2027-11-01", 11)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert {:ok, %{converted_to_credit_cents: 5, held_cents: 0}} =
             Reservations.get_payment("converted-pay")

    assert {:ok, %{refunded_cents: 20, held_cents: 0}} = Reservations.get_payment("refunded-pay")
    assert {:ok, %{retained_cents: 30, held_cents: 0}} = Reservations.get_payment("retained-pay")

    assert Repo.get_by!(CreditEntitlement,
             credit_lot_id: lot,
             payment_operation_id: "converted-pay"
           ).amount_cents == 5

    [charged] =
      Reservations.submit_batch([
        operation("charge_back_payment", %{
          "payment_operation_id" => "converted-pay",
          "expected_revision" => 7
        })
      ])

    assert charged.charged_back_cents == 5
    assert charged.revision == 8
    assert Repo.get!(CreditLot, lot).remaining_cents == 6
    assert Reservations.ledger(~D[2026-11-01]).cash_converted_to_credit_cents == 5
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 6
    assert [%{revision: 2, status: "applied"}] = Reservations.submit_batch([payment])

    assert {:ok, %{charged_back_cents: 5, converted_to_credit_cents: 0}} =
             Reservations.get_payment("converted-pay")
  end

  test "concurrent reductions and chargebacks never dispose of the same cash twice", %{
    repository: repository
  } do
    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100})
    ])

    results =
      concurrently(repository, fn _ ->
        operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 75})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reduction_exceeds_held_cash")) == 7
    charge = operation("charge_back_payment", %{"payment_operation_id" => "pay"})
    results = concurrently(repository, fn _ -> charge end)
    assert [%{charged_back_cents: 25, revision: 4}] = Enum.uniq(results)

    assert {:ok, %{recorded_cents: 100, held_cents: 0, reduced_cents: 75, charged_back_cents: 25}} =
             Reservations.get_payment("pay")

    assert Reservations.ledger().cash_reduced_cents == 75
    assert Reservations.ledger().cash_charged_back_cents == 25
  end

  test "a failed chargeback audit write rolls back cash, entitlement and shortfall changes" do
    issue_credit()

    Reservations.submit_batch([
      open_group(%{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    payment =
      Repo.one!(from record in OperationRecord, where: record.type == "record_cash_payment")

    charge =
      operation("charge_back_payment", %{
        "payment_operation_id" => payment.operation_id,
        "operation_id" => "failed-charge"
      })

    Repo.query!("""
    CREATE TRIGGER fail_charge BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'failed-charge'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    before = operation_snapshot()
    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([charge]) end
    assert operation_snapshot() == before
    assert Reservations.get_operation("failed-charge") == {:error, "operation_not_found"}
    Repo.query!("DROP TRIGGER fail_charge")
    assert [%{charged_back_cents: 100}] = Reservations.submit_batch([charge])
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 80
  end

  test "concurrent transfer retries move funding once and statements survive restart", %{
    repository: repository,
    options: options
  } do
    Reservations.submit_batch([
      open_group(),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100})
    ])

    transfer =
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "destination",
        "amount_cents" => 75,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    assert [result] = concurrently(repository, fn _ -> transfer end) |> Enum.uniq()
    assert result.status == "applied"
    assert result.source_revision == 3
    assert result.destination_revision == 2
    assert {:ok, statement} = Reservations.get_payment("pay")

    assert statement.held_by_group == [
             %{group_id: "destination", amount_cents: 75},
             %{group_id: "group-81", amount_cents: 25}
           ]

    before = operation_snapshot()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert Reservations.submit_batch([transfer]) == [result]
    assert Reservations.get_payment("pay") == {:ok, statement}
    assert operation_snapshot() == before
  end

  test "competing transfers serialize source funding and destination revision guards", %{
    repository: repository
  } do
    destinations = for index <- 1..8, do: open_group(%{"group_id" => "destination-#{index}"})

    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}) | destinations
    ])

    results =
      concurrently(repository, fn index ->
        operation("transfer_deposit", %{
          "source_group_id" => "group-81",
          "destination_group_id" => "destination-#{index}",
          "amount_cents" => 75
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_held_funding")) == 7
    assert Reservations.ledger().cash_held_cents == 100
    assert Repo.get!(Group, "group-81").revision == 3

    Reservations.submit_batch([open_group(%{"group_id" => "shared"})])

    for index <- 1..8 do
      Reservations.submit_batch([
        open_group(%{"group_id" => "source-#{index}"}),
        operation("record_cash_payment", %{"group_id" => "source-#{index}", "amount_cents" => 100})
      ])
    end

    results =
      concurrently(repository, fn index ->
        operation("transfer_deposit", %{
          "source_group_id" => "source-#{index}",
          "destination_group_id" => "shared",
          "amount_cents" => 75,
          "expected_revision" => 2,
          "destination_expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7

    assert Enum.all?(
             rejected,
             &(&1.code == "stale_revision" and &1.group_id == "shared" and &1.actual_revision == 2)
           )

    assert Reservations.ledger().cash_held_cents == 900
  end

  test "failed transfer and cross-group correction audit writes roll back every domain change" do
    issue_credit()

    Reservations.submit_batch([
      open_group(%{"group_id" => "source"}),
      open_group(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{
        "group_id" => "source",
        "operation_id" => "pay",
        "amount_cents" => 40
      }),
      operation("apply_hotel_credit", %{"group_id" => "source", "amount_cents" => 80})
    ])

    transfer =
      operation("transfer_deposit", %{
        "operation_id" => "failed-transfer",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 100
      })

    reduce =
      operation("reduce_cash_payment", %{
        "operation_id" => "failed-reduction",
        "payment_operation_id" => "pay",
        "amount_cents" => 30
      })

    charge =
      operation("charge_back_payment", %{
        "operation_id" => "failed-charge",
        "payment_operation_id" => "pay"
      })

    for {attempted, index} <- Enum.with_index([transfer, reduce, charge]) do
      Repo.query!("""
      CREATE TRIGGER fail_audit_#{index} BEFORE INSERT ON operation_records
      WHEN NEW.operation_id = '#{attempted["operation_id"]}'
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END
      """)

      before = operation_snapshot()
      assert_raise Exqlite.Error, fn -> Reservations.submit_batch([attempted]) end
      assert operation_snapshot() == before

      assert Reservations.get_operation(attempted["operation_id"]) ==
               {:error, "operation_not_found"}

      Repo.query!("DROP TRIGGER fail_audit_#{index}")
      assert [%{status: "applied"}] = Reservations.submit_batch([attempted])
    end

    assert {:ok, %{held_by_group: [], reduced_cents: 30, charged_back_cents: 10}} =
             Reservations.get_payment("pay")

    assert Repo.get!(Group, "source").revision == 6
    assert Repo.get!(Group, "destination").revision == 3
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  @tag migration_count: 4
  test "the transfer migration preserves existing slices and supports legacy cash and credit", %{
    migrations: migrations
  } do
    legacy_group("legacy", "active", 100, 40)
    legacy_group("destination", "active", 0, 0)
    lot = legacy_lot("legacy-credit", "2027-11-01", 70)
    Repo.query!("UPDATE rooms SET deposit_due_cents = 50, lodging_total_cents = 250")

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('legacy', ?, 40)",
      [lot]
    )

    for {room, cash, credit} <- [{"r1", 50, 0}, {"r2", 10, 40}] do
      Repo.query!(
        "INSERT INTO room_allocations (room_id, amount_cents) SELECT id, ? FROM rooms WHERE group_id = 'legacy' AND room_id = ?",
        [cash, room]
      )

      if credit > 0 do
        Repo.query!(
          "INSERT INTO room_allocations (room_id, amount_cents, credit_lot_id) SELECT id, ?, ? FROM rooms WHERE group_id = 'legacy' AND room_id = ?",
          [credit, lot, room]
        )
      end
    end

    before = Repo.query!("SELECT * FROM room_allocations ORDER BY id")

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
             20_260_907_000_004,
             20_260_907_000_005
           ]

    assert Repo.query!(
             "SELECT " <> Enum.join(before.columns, ", ") <> " FROM room_allocations ORDER BY id"
           ).rows == before.rows

    assert Enum.all?(Repo.all(RoomAllocation), &(not &1.transferred))
    ledger = Reservations.ledger(~D[2026-11-01])

    assert [%{status: "applied", source_revision: 8, destination_revision: 8}] =
             Reservations.submit_batch([
               operation("transfer_deposit", %{
                 "source_group_id" => "legacy",
                 "destination_group_id" => "destination",
                 "amount_cents" => 80
               })
             ])

    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Repo.get!(Group, "legacy").deposit_paid_cents == 20
    assert Repo.get!(Group, "destination").credit_paid_cents == 40

    assert [%{refunded_cents: 40}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"group_id" => "destination"})
             ])

    assert Repo.get!(CreditLot, lot).remaining_cents == 110
    assert Reservations.get_payment("legacy-payment") == {:error, "operation_not_found"}
  end

  test "concurrent reporting starts serialize and the opening position survives restart", %{
    repository: repository,
    options: options
  } do
    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    results =
      concurrently(repository, fn _ ->
        operation("start_finance_reporting", %{"starts_on" => "2026-11-01"})
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7
    assert Repo.aggregate(Inception, :count) == 1

    payment = operation("record_cash_payment", %{"amount_cents" => 50})
    assert [%{status: "applied"}] = concurrently(repository, fn _ -> payment end) |> Enum.uniq()
    assert Repo.aggregate(Movement, :count) == 1
    assert {:ok, report} = FinanceReporting.daily_report("2026-11-01")
    assert [%{opening_held_cents: 100, closing_held_cents: 150}] = report.cash
    before = operation_snapshot()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert FinanceReporting.daily_report("2026-11-01") == {:ok, report}
    [started] = Enum.filter(results, &(&1.status == "applied"))
    record = Repo.get_by!(OperationRecord, operation_id: started.operation_id)
    assert Reservations.submit_batch([record.payload]) == [started]
    Reservations.submit_batch([payment])
    assert operation_snapshot() == before
  end

  test "audit and journal failures roll back reporting inception and operation effects" do
    issue_credit()

    start =
      operation("start_finance_reporting", %{
        "operation_id" => "fail-start",
        "starts_on" => "2026-11-01"
      })

    Repo.query!("""
    CREATE TRIGGER fail_start BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fail-start'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    before = operation_snapshot()
    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([start]) end
    assert operation_snapshot() == before
    assert FinanceReporting.daily_report("2026-11-01") == {:error, "report_not_available"}
    Repo.query!("DROP TRIGGER fail_start")
    assert [%{status: "applied"}] = Reservations.submit_batch([start])

    Reservations.submit_batch([open_group(%{"group_id" => "target"})])
    payment = operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 100})

    failed =
      operation("cancel_group", %{
        "operation_id" => "fail-cancel",
        "group_id" => "target",
        "refund_method" => "hotel_credit"
      })

    Repo.query!("""
    CREATE TRIGGER fail_cancel BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fail-cancel'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([payment, failed]) end

    assert [%{classification: "received_cents", amount_cents: 100}] =
             Repo.all(from m in Movement, where: m.property_id == "ams-canal")

    before = operation_snapshot()
    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([payment, failed]) end
    assert operation_snapshot() == before
    Repo.query!("DROP TRIGGER fail_cancel")
    Reservations.submit_batch([failed])

    charge =
      operation("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})

    Repo.query!("""
    CREATE TRIGGER fail_journal BEFORE INSERT ON finance_movements
    WHEN NEW.classification = 'revoked_cents'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    before = operation_snapshot()
    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([charge]) end
    assert operation_snapshot() == before
    Repo.query!("DROP TRIGGER fail_journal")
    assert [%{status: "applied"}] = Reservations.submit_batch([charge])
  end

  @tag migration_count: 5
  test "reporting migration preserves legacy finances and snapshots unattributed funding", %{
    migrations: migrations
  } do
    # Funding with no durable identity is still a real opening balance.
    Repo.query!("""
    INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
      rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
      deposit_paid_cents, credit_paid_cents)
    VALUES ('legacy', 'guest', 'legacy-property', '2026-01-01', '2028-12-10', '2028-12-11',
      'flexible', 'flex-14', 'active', 7, 1000, 200, 100, 40)
    """)

    Repo.query!("""
    INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents, status, lodging_total_cents, deposit_due_cents)
    VALUES ('legacy', 'room', 0, 1000, 'active', 1000, 200)
    """)

    lot = legacy_lot("legacy-lot", "2027-11-01", 70)

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('legacy', ?, 40)",
      [lot]
    )

    Repo.query!(
      "INSERT INTO room_allocations (room_id, amount_cents) SELECT id, 60 FROM rooms WHERE group_id = 'legacy'"
    )

    Repo.query!(
      "INSERT INTO room_allocations (room_id, amount_cents, credit_lot_id) SELECT id, 40, ? FROM rooms WHERE group_id = 'legacy'",
      [lot]
    )

    ledger = Reservations.ledger(~D[2026-11-01])
    allocations = Repo.all(RoomAllocation)
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_907_000_005]
    assert Reservations.ledger(~D[2026-11-01]) == ledger
    assert Repo.all(RoomAllocation) == allocations
    assert Repo.all(Inception) == []
    assert Repo.all(Movement) == []

    Reservations.submit_batch([
      operation("start_finance_reporting", %{"starts_on" => "2026-11-01"})
    ])

    assert {:ok, report} = FinanceReporting.daily_report("2026-11-01")

    assert [%{property_id: "legacy-property", opening_held_cents: 60, closing_held_cents: 60}] =
             report.cash

    assert report.credit.opening_liability_cents == 110
    assert {:ok, expiry} = FinanceReporting.daily_report("2027-11-02")
    assert expiry.credit.movements["expired_cents"] == 70
    assert expiry.credit.closing_liability_cents == 40

    assert [%{status: "applied"}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"group_id" => "legacy", "occurred_on" => "2027-11-03"})
             ])

    assert {:ok, settled} = FinanceReporting.daily_report("2027-11-03")
    assert hd(settled.cash).movements["refunded_cents"] == 60
    assert settled.credit.movements["expired_cents"] == 40
    assert settled.credit.closing_liability_cents == 0
  end

  defp legacy_group(id, status, paid, credit, converted \\ 0, refunded \\ 0, retained \\ 0) do
    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, credit_paid_cents, cash_converted_to_credit_cents, cash_refunded_cents, cash_retained_cents)
      VALUES (?, 'guest-22', 'ams-canal', '2026-10-03', '2028-12-10', '2028-12-11',
        'flexible', 'flex-14', ?, 7, 1000, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        status,
        if(status == "active", do: 200, else: 0),
        paid,
        credit,
        converted,
        refunded,
        retained
      ]
    )

    for position <- 0..3,
        do:
          Repo.query!(
            "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES (?, ?, ?, 250)",
            [id, "r#{position + 1}", position]
          )
  end

  defp legacy_lot(source, expiry, remaining) do
    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, expires_on, remaining_cents) VALUES ('guest-22', ?, ?, ?)",
      [source, expiry, remaining]
    )

    [[id]] =
      Repo.query!("SELECT id FROM credit_lots WHERE source_operation_id = ?", [source]).rows

    id
  end

  defp legacy_record(id, type, group, amount, date) do
    op =
      operation(type, %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      })

    insert_legacy_record(op, %{
      operation_id: id,
      status: "applied",
      group_id: group,
      amount_cents: amount,
      revision: 2,
      outstanding_deposit_cents: 0
    })

    op
  end

  defp insert_legacy_record(op, result) do
    Repo.query!(
      "INSERT INTO operation_records (operation_id, type, payload, result) VALUES (?, ?, ?, ?)",
      [op["operation_id"], op["type"], Jason.encode!(op), Jason.encode!(result)]
    )
  end

  defp operation_snapshot do
    Map.new(
      [
        Inception,
        Movement,
        Group,
        Room,
        CreditLot,
        CreditAllocation,
        OperationRecord,
        RoomAllocation,
        CreditEntitlement
      ],
      fn schema ->
        {schema, Repo.all(schema)}
      end
    )
  end

  defp issue_credit do
    results =
      Reservations.submit_batch([
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{
          "operation_id" => "cancel_group-1",
          "refund_method" => "hotel_credit"
        })
      ])

    assert Enum.all?(results, &(&1.status == "applied"))
  end

  defp concurrently(repository, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repository)
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          [result] = Reservations.submit_batch([build_operation.(index)])
          result
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end
end
