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
  test "concurrent reporting starts and payment retries create a single journal", %{repo: repo} do
    starts =
      for id <- 1..6,
          do: operation("start-#{id}", "start_finance_reporting", %{"starts_on" => "2027-05-02"})

    results = race(repo, starts) |> List.flatten()
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 5
    Reservations.batch([opening()])
    payment = operation("pay", "record_cash_payment", %{"amount_cents" => 100})
    assert race(repo, List.duplicate(payment, 6)) |> Enum.uniq() |> length() == 1

    assert {:ok, %{cash: [%{closing_held_cents: 100, movements: %{"received_cents" => 100}}]}} =
             GroupStay.FinanceReporting.daily("2027-05-02")
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

    Reservations.batch([
      operation("start", "start_finance_reporting", %{"starts_on" => "2027-05-02"})
    ])

    {:ok, before_report} = GroupStay.FinanceReporting.daily("2027-05-02")

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
    assert GroupStay.FinanceReporting.daily("2027-05-02") == {:ok, before_report}
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
      operation("start", "start_finance_reporting", %{"starts_on" => "2027-05-02"}),
      operation("pay", "record_cash_payment", %{"amount_cents" => 10}),
      operation("stale", "cancel_group", %{"expected_revision" => 1})
    ]

    results = Reservations.batch(ops) |> Jason.encode!() |> Jason.decode!()
    {:ok, report} = GroupStay.FinanceReporting.daily("2027-05-02")
    assert :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.batch(ops) |> Jason.encode!() |> Jason.decode!() == results
    assert Repo.get!(Group, "group").revision == 2
    assert GroupStay.FinanceReporting.daily("2027-05-02") == {:ok, report}
    assert :ok = stop_supervised(Repo)

    # A separate BEAM starts the normal application against the same SQLite file.
    code = """
    ops = Jason.decode!(#{inspect(Jason.encode!(ops))})
    results = GroupStay.Reservations.batch(ops)
    IO.puts("DURABLE_RESULT=" <> Jason.encode!(%{
      results: results,
      report: elem(GroupStay.FinanceReporting.daily("2027-05-02"), 1),
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
    assert decoded["count"] == 4
    assert decoded["report"] == Jason.decode!(Jason.encode!(report))
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

  @tag capture_log: true
  test "concurrent transfers and cross-group corrections survive database restart", %{
    repo: repo,
    options: options
  } do
    Reservations.batch([
      opening(),
      opening("destination", "destination"),
      operation("pay", "record_cash_payment", %{"amount_cents" => 5000})
    ])

    transfer =
      operation("transfer", "transfer_deposit", %{
        "source_group_id" => "group",
        "destination_group_id" => "destination",
        "amount_cents" => 3000,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })
      |> Map.delete("group_id")

    assert [[%{source_revision: 3, destination_revision: 2}]] =
             race(repo, List.duplicate(transfer, 12)) |> Enum.uniq()

    assert Reservations.get_group("group").cash_paid_cents == 2000
    assert Reservations.get_group("destination").cash_paid_cents == 3000
    assert :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert [%{source_revision: 3, destination_revision: 2}] = Reservations.batch([transfer])

    assert {:ok,
            %{
              held_by_group: [
                %{group_id: "destination", amount_cents: 3000},
                %{group_id: "group", amount_cents: 2000}
              ]
            }} = Reservations.get_payment("pay")

    reduction =
      operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 3500
      })

    assert [[%{revision: 4}]] = race(repo, List.duplicate(reduction, 8)) |> Enum.uniq()
    assert Reservations.get_group("destination").revision == 3
    charge = operation("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    assert [[%{revision: 5}]] = race(repo, List.duplicate(charge, 8)) |> Enum.uniq()
    assert Reservations.get_group("destination").revision == 3

    assert {:ok, %{held_by_group: [], reduced_cents: 3500, charged_back_cents: 1500}} =
             Reservations.get_payment("pay")

    results = Reservations.batch([transfer, reduction, charge])
    assert :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.batch([transfer, reduction, charge]) == results
    assert {:ok, %{held_by_group: []}} = Reservations.get_payment("pay")
  end

  @tag capture_log: true
  test "concurrent closes serialize with payments and remain published across fresh VMs", %{
    repo: repo,
    database: database,
    options: options
  } do
    Reservations.batch([
      opening(),
      operation("start", "start_finance_reporting", %{"starts_on" => "2027-05-02"})
    ])

    closes =
      for id <- 1..4,
          do: operation("close-#{id}", "close_finance_period", %{"period_end_on" => "2027-05-02"})

    payments =
      for id <- 1..4, do: operation("pay-#{id}", "record_cash_payment", %{"amount_cents" => 100})

    results = race(repo, closes ++ payments) |> List.flatten()
    assert Enum.count(results, &(Map.get(&1, :period_end_on) != nil)) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 3
    {:ok, closed} = GroupStay.FinanceReporting.daily("2027-05-02")
    {:ok, open} = GroupStay.FinanceReporting.daily("2027-05-03")
    assert closed.status == "closed"
    assert hd(open.cash).closing_held_cents == 400
    published = (build_conn() |> get("/api/v1/finance/daily-report?date=2027-05-02")).resp_body
    replays = Reservations.batch(closes ++ payments) |> Jason.encode!() |> Jason.decode!()
    assert :ok = stop_supervised(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)

    assert (build_conn() |> get("/api/v1/finance/daily-report?date=2027-05-02")).resp_body ==
             published

    assert :ok = stop_supervised(Repo)

    code = """
    ops = Jason.decode!(#{inspect(Jason.encode!(closes ++ payments))})
    replays = GroupStay.Reservations.batch(ops)
    GroupStay.Reservations.batch([
      %{"operation_id" => "later-close", "type" => "close_finance_period", "occurred_on" => "2027-05-02", "period_end_on" => "2027-05-03"},
      %{"operation_id" => "later-payment", "type" => "record_cash_payment", "occurred_on" => "2027-05-02", "group_id" => "group", "amount_cents" => 50}
    ])
    IO.puts("CLOSE_RESULT=" <> Jason.encode!(%{
      replays: replays,
      published: GroupStayWeb.Endpoint.call(Plug.Test.conn(:get, "/api/v1/finance/daily-report?date=2027-05-02"), []).resp_body,
      day: elem(GroupStay.FinanceReporting.daily("2027-05-04"), 1)
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
    line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "CLOSE_RESULT="))
    assert line, output
    result = line |> String.replace_prefix("CLOSE_RESULT=", "") |> Jason.decode!()
    assert result["published"] == published
    assert result["replays"] == replays
    assert hd(result["day"]["cash"])["closing_held_cents"] == 450
    assert hd(result["day"]["late_adjustments"]["cash"])["movements"]["received_cents"] == 50
  end

  test "failed audit insertion rolls back the close cutoff" do
    Reservations.batch([
      opening(),
      operation("start", "start_finance_reporting", %{"starts_on" => "2027-05-02"})
    ])

    Repo.query!("""
    CREATE TRIGGER fail_close BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'close'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    close = operation("close", "close_finance_period", %{"period_end_on" => "2027-05-02"})

    assert_error_sent 500, fn ->
      build_conn() |> post("/api/v1/partner-batches", %{"operations" => [close]})
    end

    assert Reservations.get_operation("close") == nil
    assert {:ok, %{status: "open"}} = GroupStay.FinanceReporting.daily("2027-05-02")
    Reservations.batch([operation("pay", "record_cash_payment", %{"amount_cents" => 100})])

    assert {:ok, %{cash: [%{movements: %{"received_cents" => 100}}]}} =
             GroupStay.FinanceReporting.daily("2027-05-02")

    Repo.query!("DROP TRIGGER fail_close")
    assert [%{status: "applied"}] = Reservations.batch([close])
  end

  test "existing finance journals upgrade without changing their opening or movements" do
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)

    Repo.insert_all("finance_reporting", [
      %{id: 1, starts_on: "2027-05-02", opening_cash: ~s({"hotel":100}), opening_credit: 200}
    ])

    Repo.insert_all("finance_movements", [
      %{
        posting_on: "2027-05-02",
        property_id: "hotel",
        classification: "received_cents",
        amount_cents: 50
      },
      %{
        posting_on: "2027-05-03",
        property_id: nil,
        classification: "expired_cents",
        amount_cents: 200
      }
    ])

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_905_000_006]

    assert {:ok,
            %{
              status: "open",
              cash: [%{opening_held_cents: 100, closing_held_cents: 150}],
              late_adjustments: %{cash: []}
            }} = GroupStay.FinanceReporting.daily("2027-05-02")

    Reservations.batch([
      operation("close", "close_finance_period", %{"period_end_on" => "2027-05-03"})
    ])

    assert {:ok,
            %{
              status: "closed",
              credit: %{
                opening_liability_cents: 200,
                closing_liability_cents: 0,
                movements: %{"expired_cents" => 200}
              }
            }} = GroupStay.FinanceReporting.daily("2027-05-03")
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
