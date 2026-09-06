defmodule GroupStay.DurableOperationsTest do
  use ExUnit.Case, async: false
  import GroupStay.OperationFixture
  import Phoenix.ConnTest
  import Ecto.Query
  alias GroupStay.{Group, Operation, Repo, Reservations}
  @endpoint GroupStayWeb.Endpoint

  setup do
    directory = Path.expand("../../tmp", __DIR__)
    File.mkdir_p!(directory)
    database = Path.join(directory, "durable-#{System.unique_integer([:positive])}.db")
    options = [name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 4]
    pid = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(pid)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    # Initialize SQLite before opening competing connections to the same file.
    :ok = stop_supervised(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)

      for path <- [database, database <> "-wal", database <> "-shm"] do
        File.rm(path)
      end
    end)

    %{repo: pid, options: options, database: database}
  end

  @tag capture_log: true
  test "concurrent retries have one effect and conflicting submissions have one winner", %{
    repo: repo
  } do
    Reservations.batch([opening()])

    payment =
      operation("pay", "record_cash_payment", %{"amount_cents" => 10, "expected_revision" => 1})

    results = race(repo, List.duplicate(payment, 12))

    assert Enum.uniq(results) == [
             [
               %{
                 operation_id: "pay",
                 status: "applied",
                 group_id: "group",
                 amount_cents: 10,
                 outstanding_deposit_cents: 5990,
                 revision: 2
               }
             ]
           ]

    assert Repo.get!(Group, "group").cash_paid_cents == 10
    assert Repo.aggregate(Operation, :count) == 2

    contenders =
      for amount <- 1..8,
          do: operation("contested", "record_cash_payment", %{"amount_cents" => amount})

    results = race(repo, contenders) |> List.flatten()
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 7
    winner = Repo.get_by!(Operation, operation_id: "contested")
    assert Repo.get!(Group, "group").cash_paid_cents == 10 + winner.submission["amount_cents"]
    assert Repo.get!(Group, "group").revision == 3

    assert Enum.map(Repo.all(from o in Operation, order_by: o.id), & &1.operation_id) == [
             "open",
             "pay",
             "contested"
           ]
  end

  test "audit insertion failure rolls back domain changes, sends 500 and aborts the batch" do
    # Fail after the payment's group update, precisely at durable record insertion.
    Repo.query!("""
    CREATE TRIGGER fail_operation BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'pay'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    ops = [
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100}),
      opening("later", "later")
    ]

    assert_error_sent 500, fn ->
      build_conn() |> post("/api/v1/partner-batches", %{"operations" => ops})
    end

    assert Repo.get!(Group, "group").revision == 1
    assert Repo.get!(Group, "group").cash_paid_cents == 0
    assert Reservations.ledger().cash_held_cents == 0
    assert Reservations.get_operation("open")["revision"] == 1
    assert Reservations.get_operation("pay") == nil
    assert Reservations.get_operation("later") == nil
    assert Repo.get(Group, "later") == nil

    Repo.query!("DROP TRIGGER fail_operation")
    assert [opened, paid, later] = Reservations.batch(ops)
    assert opened.revision == 1
    assert paid.revision == 2
    assert later.revision == 1
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "credit issuance and restoration also roll back when the audit write fails" do
    Reservations.batch([
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 100}),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("target", "target"),
      operation("redeem", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 50}),
      operation("target-pay", "record_cash_payment", %{
        "group_id" => "target",
        "amount_cents" => 20
      })
    ])

    before =
      {Reservations.ledger(~D[2027-05-02]), Reservations.guest_credit("guest", ~D[2027-05-02]),
       Reservations.get_group("target")}

    Repo.query!("""
    CREATE TRIGGER fail_operation BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'settle'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    settle =
      operation("settle", "cancel_group", %{
        "group_id" => "target",
        "refund_method" => "hotel_credit"
      })

    assert_error_sent 500, fn ->
      build_conn() |> post("/api/v1/partner-batches", %{"operations" => [settle]})
    end

    assert {Reservations.ledger(~D[2027-05-02]),
            Reservations.guest_credit("guest", ~D[2027-05-02]), Reservations.get_group("target")} ==
             before

    assert Reservations.get_operation("settle") == nil
    Repo.query!("DROP TRIGGER fail_operation")
    assert [%{revision: 4, credit_issued_cents: 22}] = Reservations.batch([settle])
    assert Reservations.guest_credit("guest", ~D[2027-05-02]).available_cents == 132
  end

  test "records survive database process restart and replay in a fresh application VM", %{
    options: options,
    database: database
  } do
    ops = [
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 10}),
      operation("stale", "cancel_group", %{"expected_revision" => 1})
    ]

    results = Reservations.batch(ops) |> Jason.encode!() |> Jason.decode!()
    assert :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.batch(ops) |> Jason.encode!() |> Jason.decode!() == results
    assert Repo.get!(Group, "group").revision == 2
    assert :ok = stop_supervised(Repo)

    # A separate BEAM starts the normal application against the same SQLite file.
    code = """
    ops = Jason.decode!(#{inspect(Jason.encode!(ops))})
    results = GroupStay.Reservations.batch(ops)
    IO.puts("DURABLE_RESULT=" <> Jason.encode!(%{
      results: results,
      stored: GroupStay.Reservations.get_operation("stale"),
      group: GroupStay.Reservations.get_group("group"),
      count: GroupStay.Repo.aggregate(GroupStay.Operation, :count)
    }))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        env: [
          {"MIX_ENV", "test"},
          {"GROUP_STAY_DATABASE_PATH", database},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "DURABLE_RESULT="))
    assert line != nil, output
    decoded = line |> String.replace_prefix("DURABLE_RESULT=", "") |> Jason.decode!()
    assert decoded["results"] == results
    assert decoded["stored"] == List.last(results)
    assert decoded["group"]["revision"] == 2
    assert decoded["group"]["cash_paid_cents"] == 10
    assert decoded["count"] == 3
  end

  @tag capture_log: true
  test "concurrent reductions and chargebacks compose once and survive restart", %{
    repo: repo,
    options: options
  } do
    Reservations.batch([
      opening(),
      operation("pay", "record_cash_payment", %{"amount_cents" => 5000})
    ])

    reduction =
      operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 1000
      })

    assert race(repo, List.duplicate(reduction, 8)) |> Enum.uniq() |> length() == 1

    cancellation =
      operation("cancel-a", "cancel_rooms", %{
        "room_ids" => ["a"],
        "refund_method" => "hotel_credit"
      })

    assert race(repo, List.duplicate(cancellation, 8)) |> Enum.uniq() |> length() == 1
    charge = operation("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    assert race(repo, List.duplicate(charge, 8)) |> Enum.uniq() |> length() == 1

    assert {:ok, %{reduced_cents: 1000, charged_back_cents: 4000}} =
             Reservations.get_payment("pay")

    ops = [reduction, cancellation, charge]
    results = Reservations.batch(ops)

    state =
      {Reservations.get_group("group"), Reservations.get_payment("pay"),
       Reservations.ledger(~D[2027-05-02])}

    assert :ok = stop_supervised(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)
    assert Reservations.batch(ops) == results

    assert {Reservations.get_group("group"), Reservations.get_payment("pay"),
            Reservations.ledger(~D[2027-05-02])} == state

    assert Reservations.get_group("group").revision == 5
  end

  defp race(repo, operations) do
    tasks =
      Enum.map(operations, fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          receive do
            :go ->
              try do
                Reservations.batch([op])
              rescue
                error in Exqlite.Error ->
                  # A failed BEGIN has no effects. Model the gateway retrying a 500
                  # after the concurrent requests finish; other faults still fail.
                  if error.message == "database is locked" and
                       error.statement == "BEGIN IMMEDIATE TRANSACTION" do
                    {:retry, op}
                  else
                    reraise error, __STACKTRACE__
                  end
              end
          end
        end)
      end)

    for task <- tasks, do: send(task.pid, :go)
    results = Task.await_many(tasks, 15_000)
    assert Enum.any?(results, &is_list/1)

    Enum.map(results, fn
      {:retry, op} -> Reservations.batch([op])
      result -> result
    end)
  end
end
