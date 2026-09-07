defmodule GroupStay.DurableOperationsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record

  @endpoint GroupStayWeb.Endpoint
  @moduletag :capture_log

  # Real commits and independent connections are necessary here: a shared sandbox
  # transaction would hide both lock races and operation-level rollback failures.
  setup do
    token = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    database = Path.expand("_build/durable-#{token}.db")

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)

    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 50
    ]

    # Initialize WAL with one connection before starting competing connections.
    repo = start_repo(Keyword.put(options, :pool_size, 1))
    Repo.put_dynamic_repo(repo)

    migrations = [
      {20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups, "create_groups"},
      {20_260_907_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics,
       "add_cancellation_economics"},
      {20_260_907_000_002, GroupStay.Repo.Migrations.CreateOperations, "create_operations"},
      {20_260_907_000_003, GroupStay.Repo.Migrations.AddRoomAccounting, "add_room_accounting"},
      {20_260_907_000_004, GroupStay.Repo.Migrations.AddDepositTransfers, "add_deposit_transfers"}
    ]

    for {version, module, name} <- migrations do
      unless Code.ensure_loaded?(module) do
        Code.require_file(
          Application.app_dir(:group_stay, "priv/repo/migrations/#{version}_#{name}.exs")
        )
      end
    end

    Ecto.Migrator.run(
      Repo,
      Enum.map(migrations, fn {version, module, _} -> {version, module} end),
      :up,
      all: true,
      log: false
    )

    stop_supervised!(:durable_repo)
    repo = start_repo(options)
    Repo.put_dynamic_repo(repo)

    %{repo: repo, options: options}
  end

  defp start_repo(options) do
    start_supervised!(Supervisor.child_spec({Repo, options}, id: :durable_repo))
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100_000}]
    }
  end

  defp payment(id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group",
      "amount_cents" => amount,
      "expected_revision" => 1
    }
  end

  defp concurrent(repo, submissions) do
    parent = self()

    tasks =
      for submission <- submissions do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              try do
                Reservations.submit_batch([submission]) |> hd()
              rescue
                error in Exqlite.Error ->
                  # A contending SQLite writer may time out before entering its
                  # transaction. Simulate the gateway retrying that server fault.
                  if error.statement == "BEGIN IMMEDIATE TRANSACTION" and
                       error.message == "database is locked" do
                    {:lock_timeout, submission}
                  else
                    reraise error, __STACKTRACE__
                  end
              end
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)
    assert Enum.any?(results, &is_map/1)

    Enum.map(results, fn
      {:lock_timeout, submission} -> Reservations.submit_batch([submission]) |> hd()
      result -> result
    end)
  end

  test "concurrent exact retries have one effect and one record", %{repo: repo} do
    Reservations.submit_batch([opening()])
    submission = Map.delete(payment("pay", 100), "expected_revision")
    results = concurrent(repo, List.duplicate(submission, 12))
    assert [%{"status" => "applied", "revision" => 2}] = Enum.uniq(results)
    assert {:ok, %{cash_paid_cents: 100, revision: 2}} = Reservations.get_group("group")
    assert Repo.aggregate(Record, :count) == 2
  end

  test "transfers commit once across concurrent retries and survive restart", %{
    repo: repo,
    options: options
  } do
    destination =
      opening() |> Map.merge(%{"operation_id" => "open-d", "group_id" => "destination"})

    Reservations.submit_batch([opening(), destination, payment("pay", 100)])

    transfer = %{
      "type" => "transfer_deposit",
      "operation_id" => "transfer",
      "source_group_id" => "group",
      "destination_group_id" => "destination",
      "amount_cents" => 60,
      "occurred_on" => "2026-10-05",
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    assert [result] = concurrent(repo, List.duplicate(transfer, 8)) |> Enum.uniq()
    assert %{"source_revision" => 3, "destination_revision" => 2} = result
    {:ok, statement} = GroupStay.Reservations.Payments.statement("pay")

    assert statement.held_by_group == [
             %{group_id: "destination", amount_cents: 60},
             %{group_id: "group", amount_cents: 40}
           ]

    stop_supervised!(:durable_repo)
    Repo.put_dynamic_repo(start_repo(options))
    assert [^result] = Reservations.submit_batch([transfer])
    assert GroupStay.Reservations.Payments.statement("pay") == {:ok, statement}
    assert {:ok, %{revision: 3, cash_paid_cents: 40}} = Reservations.get_group("group")
    assert {:ok, %{revision: 2, cash_paid_cents: 60}} = Reservations.get_group("destination")
  end

  test "a transfer audit failure rolls back both groups, allocations and statement participation" do
    destination =
      opening() |> Map.merge(%{"operation_id" => "open-d", "group_id" => "destination"})

    Reservations.submit_batch([opening(), destination, payment("pay", 100)])
    before_groups = Enum.map(["group", "destination"], &Reservations.get_group/1)
    before_statement = GroupStay.Reservations.Payments.statement("pay")

    Repo.query!("""
    CREATE TRIGGER fail_transfer BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'transfer'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    transfer = %{
      "type" => "transfer_deposit",
      "operation_id" => "transfer",
      "source_group_id" => "group",
      "destination_group_id" => "destination",
      "amount_cents" => 60,
      "occurred_on" => "2026-10-05"
    }

    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([transfer]) end
    assert Enum.map(["group", "destination"], &Reservations.get_group/1) == before_groups
    assert GroupStay.Reservations.Payments.statement("pay") == before_statement
    assert Operations.fetch_result("transfer") == {:error, "operation_not_found"}
    Repo.query!("DROP TRIGGER fail_transfer")
    assert [%{"status" => "applied"}] = Reservations.submit_batch([transfer])
  end

  test "concurrent corrections have one effect and survive a database restart", %{
    repo: repo,
    options: options
  } do
    Reservations.submit_batch([opening(), payment("pay", 100)])

    reduction = %{
      "type" => "reduce_cash_payment",
      "operation_id" => "reduce",
      "payment_operation_id" => "pay",
      "amount_cents" => 30,
      "occurred_on" => "2026-10-05"
    }

    assert [%{"amount_cents" => 30, "revision" => 3}] =
             concurrent(repo, List.duplicate(reduction, 8)) |> Enum.uniq()

    chargeback = %{
      "type" => "charge_back_payment",
      "operation_id" => "charge",
      "payment_operation_id" => "pay",
      "occurred_on" => "2026-10-06"
    }

    assert [%{"charged_back_cents" => 70, "revision" => 4}] =
             concurrent(repo, List.duplicate(chargeback, 8)) |> Enum.uniq()

    {:ok, statement} = GroupStay.Reservations.Payments.statement("pay")
    assert statement.reduced_cents == 30
    assert statement.charged_back_cents == 70
    results = Reservations.submit_batch([reduction, chargeback])
    stop_supervised!(:durable_repo)
    Repo.put_dynamic_repo(start_repo(options))
    assert Reservations.submit_batch([reduction, chargeback]) == results
    assert GroupStay.Reservations.Payments.statement("pay") == {:ok, statement}
    assert {:ok, %{revision: 4, cash_paid_cents: 0}} = Reservations.get_group("group")
  end

  test "a failed chargeback audit rolls back credit revocation and payment dispositions" do
    cancel = %{
      "type" => "cancel_group",
      "operation_id" => "cancel",
      "group_id" => "group",
      "occurred_on" => "2026-10-05",
      "refund_method" => "hotel_credit"
    }

    Reservations.submit_batch([opening(), payment("pay", 100), cancel])
    before_ledger = Reservations.ledger(~D[2026-10-05])
    before_statement = GroupStay.Reservations.Payments.statement("pay")

    Repo.query!("""
    CREATE TRIGGER fail_chargeback BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'charge'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    chargeback = %{
      "type" => "charge_back_payment",
      "operation_id" => "charge",
      "payment_operation_id" => "pay",
      "occurred_on" => "2026-10-06"
    }

    assert_raise Exqlite.Error, fn -> Reservations.submit_batch([chargeback]) end
    assert Reservations.ledger(~D[2026-10-05]) == before_ledger
    assert GroupStay.Reservations.Payments.statement("pay") == before_statement
    assert Operations.fetch_result("charge") == {:error, "operation_not_found"}
    assert {:ok, %{revision: 3}} = Reservations.get_group("group")
    Repo.query!("DROP TRIGGER fail_chargeback")

    assert [%{"charged_back_cents" => 100, "revision" => 4}] =
             Reservations.submit_batch([chargeback])
  end

  test "concurrent conflicting payloads preserve whichever submission commits first", %{
    repo: repo
  } do
    Reservations.submit_batch([opening()])
    results = concurrent(repo, [payment("pay", 100), payment("pay", 200)])
    assert Enum.sort(Enum.map(results, & &1["status"])) == ["applied", "rejected"]
    assert Enum.find(results, &(&1["status"] == "rejected"))["code"] == "operation_id_conflict"
    record = Repo.get_by!(Record, operation_id: "pay")
    assert record.result["amount_cents"] == record.payload["amount_cents"]
    assert {:ok, group} = Reservations.get_group("group")
    assert group.cash_paid_cents == record.payload["amount_cents"]
    assert group.revision == 2
  end

  test "journal survives closing and restarting all database connections", %{options: options} do
    submissions = [payment("missing", 100), opening(), payment("pay", 100)]
    results = Reservations.submit_batch(submissions)
    records = Repo.all(from r in Record, order_by: r.id)
    stop_supervised!(:durable_repo)
    repo = start_repo(options)
    Repo.put_dynamic_repo(repo)

    assert Reservations.submit_batch(submissions) == results
    assert Repo.all(from r in Record, order_by: r.id) == records

    for result <- results do
      assert Operations.fetch_result(result["operation_id"]) == {:ok, result}
    end

    assert {:ok, %{cash_paid_cents: 100, revision: 2}} = Reservations.get_group("group")
  end

  test "results survive fresh application runtimes", %{options: options} do
    submissions = [payment("missing", 100), opening(), payment("pay", 100)]

    script = """
    submissions = Jason.decode!(#{inspect(Jason.encode!(submissions))})
    results = GroupStay.Reservations.submit_batch(submissions)
    IO.puts("RESULT=" <> Jason.encode!(results))
    """

    run = fn ->
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "-e", script],
          env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", options[:database]}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      [_, json] = Regex.run(~r/^RESULT=(.+)$/m, output)
      Jason.decode!(json)
    end

    original = run.()
    assert run.() == original
    assert [%{"code" => "group_not_found"}, %{"revision" => 1}, %{"revision" => 2}] = original
    assert Repo.aggregate(Record, :count) == 3
    assert {:ok, %{cash_paid_cents: 100, revision: 2}} = Reservations.get_group("group")
  end

  test "unexpected persistence faults return 500, roll back the operation and abort the batch" do
    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'pay'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    submissions = [opening(), payment("pay", 100), payment("later", 200)]

    assert {500, _, _} =
             assert_error_sent(500, fn ->
               build_conn() |> post("/api/v1/partner-batches", %{"operations" => submissions})
             end)

    assert {:ok, %{cash_paid_cents: 0, revision: 1}} = Reservations.get_group("group")
    assert Repo.aggregate(Record, :count) == 1
    assert Operations.fetch_result("pay") == {:error, "operation_not_found"}
    assert Operations.fetch_result("later") == {:error, "operation_not_found"}
    Repo.query!("DROP TRIGGER fail_audit")

    assert [%{"revision" => 1}, %{"revision" => 2}, %{"code" => "stale_revision"}] =
             Reservations.submit_batch(submissions)

    assert {:ok, %{cash_paid_cents: 100, revision: 2}} = Reservations.get_group("group")
    assert Repo.aggregate(Record, :count) == 3
  end
end
