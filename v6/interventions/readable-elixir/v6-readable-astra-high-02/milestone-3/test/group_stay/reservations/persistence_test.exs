defmodule GroupStay.Reservations.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, OperationRecord, Room}

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
             20_260_907_000_002
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
    {:ok, changeset, _result} = Group.open(open_group(), ~D[2026-10-03])
    group = Repo.insert!(changeset)

    group
    |> Ecto.Changeset.change(deposit_paid_cents: 100, credit_paid_cents: 80, revision: 3)
    |> Repo.update!()

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: "legacy-cancellation",
        remaining_cents: 30,
        expires_on: ~D[2027-11-01]
      })

    Repo.insert!(%CreditAllocation{
      group_id: group.group_id,
      credit_lot_id: lot.id,
      amount_cents: 80
    })

    before = Map.new([Group, Room, CreditLot, CreditAllocation], &{&1, Repo.all(&1)})

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_907_000_002]
    assert Repo.all(OperationRecord) == []
    for {schema, rows} <- before, do: assert(Repo.all(schema) == rows)

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
      operation("record_cash_payment", %{"amount_cents" => 100}),
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

  defp operation_snapshot do
    Map.new([Group, Room, CreditLot, CreditAllocation, OperationRecord], fn schema ->
      {schema, Repo.all(schema)}
    end)
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
