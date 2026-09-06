defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo, Reservations}

  @endpoint GroupStayWeb.Endpoint

  @moduletag capture_log: true

  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_100, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_200, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_905_000_300, GroupStay.Repo.Migrations.AddRoomAccounting},
    {20_260_905_000_400, GroupStay.Repo.Migrations.AddDepositTransfers},
    {20_260_905_000_500, GroupStay.Repo.Migrations.AddFinanceReporting},
    {20_260_905_000_600, GroupStay.Repo.Migrations.AddFinancePeriodClose}
  ]

  setup_all do
    for {version, module} <- @migrations do
      unless Code.ensure_loaded?(module) do
        [path] = Path.wildcard("priv/repo/migrations/#{version}_*.exs")
        Code.require_file(path)
      end
    end

    :ok
  end

  defp migrate do
    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
  end

  setup do
    directory = Path.expand("tmp/persistence-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 50
    ]

    # Initialize the file with one connection before opening the concurrent pool,
    # so new connections do not race to enable SQLite's WAL journal mode.
    initial_repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(initial_repo)
    migrate()
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    %{repo: repo, options: options}
  end

  # SQLite can finish cleaning up WAL sidecars just after its pool shuts down.
  defp remove_database_directory(directory, retries \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        Process.sleep(10)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, path: path, action: "remove test database"
    end
  end

  defp opening do
    %{
      "operation_id" => "open-#{System.unique_integer([:positive])}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => "persistent",
      "guest_id" => "guest",
      "property_id" => "property",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }
  end

  defp payment(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{System.unique_integer([:positive])}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "persistent",
        "amount_cents" => 2000
      },
      overrides
    )
  end

  defp concurrently(repo, op, retries \\ false) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              operation =
                if retries,
                  do: op,
                  else: Map.put(op, "operation_id", "#{op["operation_id"]}-#{index}")

              Reservations.apply_batch([operation]) |> hd()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    Task.await_many(tasks, 30_000)
  end

  test "finance inception and concurrent retry movements survive application restart", %{
    repo: repo,
    options: options
  } do
    Reservations.apply_batch([opening(), payment(%{"operation_id" => "opening-pay"})])

    start = %{
      "operation_id" => "start-finance",
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-01-02",
      "starts_on" => "2026-01-01"
    }

    assert [%{status: "applied", starts_on: "2026-01-01"} = original] =
             Enum.uniq(concurrently(repo, start, true))

    pay = payment(%{"operation_id" => "reported-pay", "amount_cents" => 500})
    assert [%{status: "applied"}] = Enum.uniq(concurrently(repo, pay, true))
    {:ok, report} = GroupStay.FinanceReporting.daily_report("2026-01-02")

    assert [
             %{
               opening_held_cents: 2000,
               closing_held_cents: 2500,
               movements: %{"received_cents" => 500}
             }
           ] = report.cash

    entries = Repo.all(GroupStay.FinanceEntry)
    stop_supervised!(Repo)

    code = """
    alias GroupStay.{FinanceReporting, Reservations}
    start = Jason.decode!(#{inspect(Jason.encode!(start))})
    expected = Jason.decode!(#{inspect(Jason.encode!(report))})
    {:ok, report} = FinanceReporting.daily_report("2026-01-02")
    if Jason.decode!(Jason.encode!(report)) != expected, do: raise("finance report changed")
    [result] = Reservations.apply_batch([start])
    if result.status != "applied", do: raise("inception did not replay")
    """

    {output, status} =
      System.cmd("mix", ["run", "-e", code],
        env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", options[:database]}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert migrate() == []
    assert Reservations.apply_batch([start]) == [original]
    assert GroupStay.FinanceReporting.daily_report("2026-01-02") == {:ok, report}
    assert Repo.all(GroupStay.FinanceEntry) == entries
  end

  test "competing starts choose one durable inception and a failed audit leaves none", %{
    repo: repo
  } do
    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-01-01"
    }

    Repo.query!(
      "CREATE TRIGGER fail_start BEFORE INSERT ON operations WHEN NEW.operation_id = 'start' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    assert_raise Exqlite.Error, fn -> Reservations.apply_batch([start]) end
    assert Repo.all(GroupStay.FinanceReporting) == []
    assert Repo.all(GroupStay.FinanceEntry) == []
    Repo.query!("DROP TRIGGER fail_start")
    results = concurrently(repo, start)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reporting_already_started")) == 7
    assert Repo.aggregate(GroupStay.FinanceReporting, :count) == 1
  end

  test "concurrent closes and payments select posting dates in durable commit order", %{
    repo: repo
  } do
    alias GroupStay.{FinanceEntry, FinanceReporting}

    Reservations.apply_batch([
      opening(),
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      }
    ])

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-01-02"
    }

    operations = [
      close | for(i <- 1..8, do: payment(%{"operation_id" => "race-#{i}", "amount_cents" => 100}))
    ]

    results =
      operations
      |> Enum.map(fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          Reservations.apply_batch([op])
        end)
      end)
      |> Task.await_many(30_000)
      |> List.flatten()

    assert Enum.all?(results, &(&1.status == "applied"))

    close_record = Repo.get_by!(Operation, operation_id: "close")

    for entry <- Repo.all(FinanceEntry) do
      record = Repo.get_by!(Operation, operation_id: entry.operation_id)
      late? = record.id > close_record.id
      assert entry.late_adjustment == late?
      assert entry.posting_on == if(late?, do: ~D[2026-01-03], else: ~D[2026-01-02])
    end

    {:ok, published} = FinanceReporting.daily_report("2026-01-02")
    assert published.status == "closed"

    assert [%{period_end_on: "2026-01-02", status: "applied"}] =
             Enum.uniq(concurrently(repo, close, true))

    next = Map.merge(close, %{"operation_id" => "next", "period_end_on" => "2026-01-03"})
    results = concurrently(repo, next)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "invalid_period")) == 7
    assert FinanceReporting.daily_report("2026-01-02") == {:ok, published}
    {:ok, report} = FinanceReporting.daily_report("2026-01-04")
    assert [%{closing_held_cents: 800}] = report.cash
  end

  test "closed data and exact close retries survive a separate application process", %{
    options: options
  } do
    alias GroupStay.FinanceReporting

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "period_end_on" => "2026-01-02"
    }

    [_, _, _, original] =
      Reservations.apply_batch([
        opening(),
        %{
          "operation_id" => "start",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-01-01"
        },
        payment(),
        close
      ])

    {:ok, report} = FinanceReporting.daily_report("2026-01-02")

    published =
      build_conn() |> get("/api/v1/finance/daily-report?date=2026-01-02") |> response(200)

    late = payment(%{"operation_id" => "late", "amount_cents" => 100})
    stop_supervised!(Repo)

    code = """
    alias GroupStay.Reservations
    close = Jason.decode!(#{inspect(Jason.encode!(close))})
    expected = #{inspect(published)}
    read = fn ->
      conn = Plug.Test.conn(:get, "/api/v1/finance/daily-report?date=2026-01-02")
      GroupStayWeb.Endpoint.call(conn, GroupStayWeb.Endpoint.init([])).resp_body
    end
    if read.() != expected, do: raise("published bytes changed after restart")
    Reservations.apply_batch([Jason.decode!(#{inspect(Jason.encode!(late))})])
    [result] = Reservations.apply_batch([close])
    if Jason.decode!(Jason.encode!(result)) != Jason.decode!(#{inspect(Jason.encode!(original))}), do: raise("close retry changed")
    if read.() != expected, do: raise("late operation changed published bytes")
    """

    {output, status} =
      System.cmd("mix", ["run", "-e", code],
        env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", options[:database]}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.apply_batch([close]) == [original]
    assert FinanceReporting.daily_report("2026-01-02") == {:ok, report}
    {:ok, open} = FinanceReporting.daily_report("2026-01-03")
    assert [%{movements: %{"received_cents" => 100}}] = open.late_adjustments.cash
    assert [%{closing_held_cents: 2100}] = open.cash
  end

  test "period-close migration preserves existing inception, movements, expiry and audit records" do
    alias GroupStay.{FinanceEntry, FinanceReporting}

    Reservations.apply_batch([
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      }
    ])

    create_credit()
    dates = ~w(2026-01-01 2026-01-02 2027-01-03)
    reports = Enum.map(dates, &FinanceReporting.daily_report/1)

    snapshot =
      {Repo.all(Operation), Repo.all(FinanceEntry), Repo.all(FinanceReporting),
       Reservations.ledger(~D[2026-01-02])}

    Ecto.Migrator.run(Repo, @migrations, :down, step: 1, log: false)
    assert migrate() == [20_260_905_000_600]
    assert migrate() == []

    assert {Repo.all(Operation), Repo.all(FinanceEntry), Repo.all(FinanceReporting),
            Reservations.ledger(~D[2026-01-02])} == snapshot

    assert Enum.map(dates, &FinanceReporting.daily_report/1) == reports
    assert Enum.all?(Repo.all(FinanceEntry), &(&1.late_adjustment == false))

    assert [%{status: "applied"}] =
             Reservations.apply_batch([
               %{
                 "operation_id" => "close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-03"
               }
             ])

    for {on, {:ok, report}} <- Enum.zip(dates, reports) do
      assert FinanceReporting.daily_report(on) == {:ok, %{report | status: "closed"}}
    end
  end

  test "finance migration preserves existing state and starts reporting only on request" do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "target"),
      payment(%{"group_id" => "target", "type" => "apply_hotel_credit", "amount_cents" => 1000}),
      payment(%{"group_id" => "target", "amount_cents" => 500})
    ])

    snapshot = fn ->
      {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation), Repo.all(Operation),
       Reservations.ledger(~D[2026-01-03])}
    end

    before = snapshot.()
    Ecto.Migrator.run(Repo, @migrations, :down, step: 2, log: false)
    assert migrate() == [20_260_905_000_500, 20_260_905_000_600]
    assert migrate() == []
    assert snapshot.() == before

    assert GroupStay.FinanceReporting.daily_report("2026-01-03") ==
             {:error, "report_not_available"}

    Reservations.apply_batch([
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-03"
      }
    ])

    {:ok, report} = GroupStay.FinanceReporting.daily_report("2026-01-03")
    assert report.credit.opening_liability_cents == 2200
    assert [%{opening_held_cents: 500, closing_held_cents: 500}] = report.cash
    {:ok, expiry} = GroupStay.FinanceReporting.daily_report("2027-01-03")
    assert expiry.credit.movements["expired_cents"] == 1200
    assert expiry.credit.closing_liability_cents == 1000
  end

  test "concurrent conditional payments have exactly one winner", %{repo: repo} do
    Reservations.apply_batch([opening()])
    results = concurrently(repo, payment(%{"expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert %{revision: 2, deposit_paid_cents: 2000} = Reservations.get_group("persistent")
    assert Reservations.ledger().cash_held_cents == 2000
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.apply_batch([opening()])
    results = concurrently(repo, payment())
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 6

    assert %{revision: 3, deposit_paid_cents: 4000, outstanding_deposit_cents: 0} =
             Reservations.get_group("persistent")

    assert Reservations.ledger().cash_held_cents == 4000
  end

  test "concurrent opening preserves uniqueness", %{repo: repo} do
    results = concurrently(repo, opening())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("persistent").revision == 1
  end

  test "migrations are repeatable and groups and settlements survive repository restarts", %{
    options: options
  } do
    Reservations.apply_batch([opening(), payment()])
    group = Reservations.get_group("persistent")
    ledger = Reservations.ledger()

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert migrate() == []
    assert Reservations.get_group("persistent") == group
    assert Reservations.ledger() == ledger

    assert [%{refunded_cents: 2000, revision: 3}] =
             Reservations.apply_batch([
               payment(%{"type" => "cancel_group", "expected_revision" => 2})
             ])

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert %{status: "cancelled", revision: 3, outstanding_deposit_cents: 0} =
             Reservations.get_group("persistent")

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 2000,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "a busy transaction retries without applying a payment twice", %{
    repo: repo,
    options: options
  } do
    Reservations.apply_batch([opening()])
    {:ok, blocker} = Exqlite.Sqlite3.open(options[:database])
    on_exit(fn -> Exqlite.Sqlite3.close(blocker) end)
    :ok = Exqlite.Sqlite3.execute(blocker, "BEGIN IMMEDIATE TRANSACTION")

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Reservations.apply_batch([payment(%{"expected_revision" => 1})])
      end)

    # Hold the external writer lock beyond the connection's busy timeout.
    assert Task.yield(task, 160) == nil
    :ok = Exqlite.Sqlite3.execute(blocker, "COMMIT")
    assert [%{status: "applied", revision: 2}] = Task.await(task, 5000)
    assert %{revision: 2, deposit_paid_cents: 2000} = Reservations.get_group("persistent")
    assert Reservations.ledger().cash_held_cents == 2000
  end

  test "upgrade backfills original booking policies and preserves existing accounting" do
    Ecto.Migrator.run(Repo, @migrations, :down, step: 6, log: false)

    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2027-01-01", "advance_purchase", "active", 300, 0, 0},
          {"settled", "2026-01-01", "flexible", "cancelled", 0, 50, 0},
          {"retained", "2026-01-01", "advance_purchase", "cancelled", 0, 0, 70}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2028-06-01', '2028-06-02', ?, ?, 4,
          '[{"room_id":"room","nightly_rate_cents":10000}]', 10000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active", do: 2000, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert migrate() == [
             20_260_905_000_100,
             20_260_905_000_200,
             20_260_905_000_300,
             20_260_905_000_400,
             20_260_905_000_500,
             20_260_905_000_600
           ]

    assert migrate() == []

    for {id, policy, paid, until} <- [
          {"old", "flex-14", 100, ~D[2028-05-18]},
          {"new", "flex-30", 200, ~D[2028-05-02]},
          {"advance", "advance-nonrefundable", 300, nil}
        ] do
      assert %{
               policy_version: ^policy,
               revision: 4,
               cash_paid_cents: ^paid,
               deposit_paid_cents: ^paid,
               credit_paid_cents: 0,
               refundable_until: ^until
             } = Reservations.get_group(id)
    end

    assert Reservations.get_group("settled").status == "cancelled"

    assert Reservations.ledger() == %{
             cash_held_cents: 600,
             cash_refunded_cents: 50,
             cash_retained_cents: 70,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0,
             credit_shortfall_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{refunded_cents: 100, revision: 5}] =
             Reservations.apply_batch([
               payment(%{
                 "type" => "cancel_group",
                 "group_id" => "old",
                 "occurred_on" => "2028-05-18",
                 "expected_revision" => 4
               })
             ])
  end

  defp create_credit do
    assert [_, _, %{credit_issued_cents: 2200}] =
             Reservations.apply_batch([
               opening(),
               payment(),
               payment(%{
                 "operation_id" => "pay-credit",
                 "type" => "cancel_group",
                 "refund_method" => "hotel_credit"
               })
             ])
  end

  test "credit lots and their active allocations survive restarts and restore to the original expiry",
       %{options: options} do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "target"),
      payment(%{"type" => "apply_hotel_credit", "group_id" => "target", "amount_cents" => 1500})
    ])

    before = Reservations.ledger(~D[2026-01-02])
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.ledger(~D[2026-01-02]) == before

    assert %{credit_paid_cents: 1500, cash_paid_cents: 0, revision: 2} =
             Reservations.get_group("target")

    assert %{available_cents: 700} = Reservations.guest_credit("guest", ~D[2026-01-02])

    assert [%{revision: 3, credit_issued_cents: 0}] =
             Reservations.apply_batch([
               payment(%{"type" => "cancel_group", "group_id" => "target"})
             ])

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert %{
             available_cents: 2200,
             lots: [%{source_operation_id: "pay-credit", expires_on: ~D[2027-01-02]}]
           } =
             Reservations.guest_credit("guest", ~D[2027-01-02])

    assert Reservations.ledger(~D[2027-01-03]).credit_liability_cents == 0
  end

  test "concurrent redemption across groups cannot spend the same guest credit twice", %{
    repo: repo
  } do
    create_credit()

    for index <- 1..8 do
      Reservations.apply_batch([Map.put(opening(), "group_id", "target-#{index}")])
    end

    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              Reservations.apply_batch([
                payment(%{
                  "type" => "apply_hotel_credit",
                  "group_id" => "target-#{index}",
                  "amount_cents" => 1100
                })
              ])
              |> hd()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    results = Task.await_many(tasks, 30_000)
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 6
    assert Reservations.guest_credit("guest", ~D[2026-01-02]).available_cents == 0
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 2200
  end

  test "concurrent credit cancellations create exactly one lot", %{repo: repo} do
    Reservations.apply_batch([opening(), payment()])

    results =
      concurrently(
        repo,
        payment(%{
          "type" => "cancel_group",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        })
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7

    assert %{available_cents: 2200, lots: [_]} =
             Reservations.guest_credit("guest", ~D[2026-01-02])

    assert Reservations.ledger().cash_converted_to_credit_cents == 2000
  end

  test "concurrent exact retries apply once and return identical original results", %{repo: repo} do
    open = opening()
    results = concurrently(repo, open, true)

    assert Enum.uniq(results) == [
             %{
               operation_id: open["operation_id"],
               status: "applied",
               group_id: "persistent",
               deposit_due_cents: 4000,
               revision: 1
             }
           ]

    pay = payment(%{"expected_revision" => 1})
    results = concurrently(repo, pay, true)
    assert [%{status: "applied", revision: 2}] = Enum.uniq(results)
    assert %{cash_paid_cents: 2000, revision: 2} = Reservations.get_group("persistent")

    cancel =
      payment(%{
        "type" => "cancel_group",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      })

    results = concurrently(repo, cancel, true)
    assert [%{status: "applied", revision: 3, credit_issued_cents: 2200}] = Enum.uniq(results)
    assert Repo.aggregate(CreditLot, :count) == 1
    assert Reservations.ledger().cash_converted_to_credit_cents == 2000

    rejected = payment(%{"expected_revision" => 1})
    results = concurrently(repo, rejected, true)
    assert [%{code: "stale_revision", actual_revision: 3}] = Enum.uniq(results)
    assert Repo.aggregate(Operation, :count) == 4
    assert Reservations.get_group("persistent").revision == 3

    Reservations.apply_batch([Map.put(opening(), "group_id", "target")])

    redeem =
      payment(%{"type" => "apply_hotel_credit", "group_id" => "target", "amount_cents" => 500})

    results = concurrently(repo, redeem, true)
    assert [%{status: "applied", revision: 2}] = Enum.uniq(results)
    assert Reservations.get_group("target").credit_paid_cents == 500
    assert Reservations.guest_credit("guest", ~D[2026-01-02]).available_cents == 1700
    assert Repo.aggregate(CreditAllocation, :count) == 1
    assert Repo.aggregate(Operation, :count) == 6
  end

  test "concurrent different payloads for one ID keep only the winning submission", %{repo: repo} do
    Reservations.apply_batch([opening()])

    results =
      1..8
      |> Enum.map(fn amount ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          operation = payment(%{"operation_id" => "contended", "amount_cents" => amount})
          {operation, hd(Reservations.apply_batch([operation]))}
        end)
      end)
      |> Task.await_many(30_000)

    [{winner, result}] = Enum.filter(results, fn {_, result} -> result.status == "applied" end)

    assert Enum.count(results, fn {_, result} ->
             Map.get(result, :code) == "operation_id_conflict"
           end) == 7

    record = Repo.get_by!(Operation, operation_id: "contended")
    assert record.submission == winner
    assert record.result == Jason.decode!(Jason.encode!(result))
    assert Reservations.get_group("persistent").cash_paid_cents == winner["amount_cents"]
    assert Reservations.get_group("persistent").revision == 2
    assert Repo.aggregate(Operation, :count) == 2
  end

  test "an unexpected failure rolls back accounting and audit, aborts HTTP, and permits batch retry" do
    create_credit()
    target = Map.put(opening(), "group_id", "target")

    Reservations.apply_batch([
      target,
      payment(%{"type" => "apply_hotel_credit", "group_id" => "target", "amount_cents" => 1000}),
      payment(%{"group_id" => "target", "amount_cents" => 100})
    ])

    before = {Repo.all(Group), Repo.all(CreditLot), Repo.all(CreditAllocation)}

    cancel =
      payment(%{
        "operation_id" => "fault",
        "type" => "cancel_group",
        "group_id" => "target",
        "refund_method" => "hotel_credit"
      })

    first =
      Map.merge(opening(), %{"operation_id" => "before-fault", "group_id" => "before-fault"})

    last = Map.put(opening(), "group_id", "after-fault")
    operations = [first, cancel, last]

    # Fail audit insertion after cancellation has issued a lot, restored an
    # allocation, deleted that allocation, and updated the group's accounting.
    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_error_sent 500, fn ->
      post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    end

    assert {Repo.all(from g in Group, where: g.group_id != "before-fault"), Repo.all(CreditLot),
            Repo.all(CreditAllocation)} == before

    assert Reservations.get_operation("before-fault")["revision"] == 1
    assert Reservations.get_group("before-fault").revision == 1
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_operation(last["operation_id"]) == nil
    assert Reservations.get_group("after-fault") == nil
    first_record = Repo.get_by!(Operation, operation_id: "before-fault")

    Repo.query!("DROP TRIGGER fail_audit")

    assert [%{revision: 1}, %{credit_issued_cents: 110, revision: 4}, %{revision: 1}] =
             Reservations.apply_batch(operations)

    assert Repo.get_by!(Operation, operation_id: "before-fault") == first_record
    assert Reservations.guest_credit("guest", ~D[2026-01-02]).available_cents == 2310
    assert Reservations.get_group("target").status == "cancelled"
    records = Repo.all(from o in Operation, order_by: o.id)

    assert Enum.map(Enum.take(records, -3), & &1.operation_id) == [
             "before-fault",
             "fault",
             last["operation_id"]
           ]
  end

  test "durable submissions and results survive database and fresh application restarts", %{
    options: options
  } do
    operations = [opening(), payment(), payment(%{"expected_revision" => 0})]
    results = Reservations.apply_batch(operations)
    records = Repo.all(from o in Operation, order_by: o.id)
    stop_supervised!(Repo)

    # A separate BEAM instance starts the application against the same file.
    # Replaying there verifies that no in-memory state supplies the guarantee.
    code = """
    alias GroupStay.{Operation, Repo, Reservations}
    operations = Jason.decode!(#{inspect(Jason.encode!(operations))})
    expected = Jason.decode!(#{inspect(Jason.encode!(results))})
    actual = Reservations.apply_batch(operations) |> Jason.encode!() |> Jason.decode!()
    if actual != expected, do: raise("results changed after application restart")
    if Repo.aggregate(Operation, :count) != 3, do: raise("unexpected durable records")
    if Reservations.get_group("persistent").revision != 2, do: raise("payment replayed")
    """

    {output, status} =
      System.cmd("mix", ["run", "-e", code],
        env: [{"MIX_ENV", "test"}, {"GROUP_STAY_DATABASE_PATH", options[:database]}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.apply_batch(operations) == results
    assert Repo.all(from o in Operation, order_by: o.id) == records

    for {operation, result} <- Enum.zip(operations, results) do
      assert Reservations.get_operation(operation["operation_id"]) ==
               Jason.decode!(Jason.encode!(result))
    end
  end

  test "upgrading the previous release preserves credit accounting and starts an empty audit" do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "target"),
      payment(%{"type" => "apply_hotel_credit", "group_id" => "target", "amount_cents" => 1000})
    ])

    before =
      {Repo.all(Group), Repo.all(CreditLot),
       Enum.map(
         Repo.all(CreditAllocation),
         &Map.take(&1, [:group_id, :room_id, :credit_lot_id, :amount_cents])
       ), Reservations.ledger()}

    Ecto.Migrator.run(Repo, @migrations, :down, step: 5, log: false)

    assert migrate() == [
             20_260_905_000_200,
             20_260_905_000_300,
             20_260_905_000_400,
             20_260_905_000_500,
             20_260_905_000_600
           ]

    assert migrate() == []
    assert Repo.all(Operation) == []

    assert {Repo.all(Group), Repo.all(CreditLot),
            Enum.map(
              Repo.all(CreditAllocation),
              &Map.take(&1, [:group_id, :room_id, :credit_lot_id, :amount_cents])
            ), Reservations.ledger()} == before

    [result] =
      Reservations.apply_batch([
        payment(%{
          "operation_id" => "new-namespace",
          "group_id" => "target",
          "amount_cents" => 1,
          "expected_revision" => 2
        })
      ])

    assert result.revision == 3
    assert Reservations.get_operation("new-namespace")["revision"] == 3
  end

  test "room upgrade allocates the legacy senior block before typed durable funding in commit order" do
    Ecto.Migrator.run(Repo, @migrations, :down, step: 4, log: false)
    rooms = for i <- 0..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_paid_cents, credit_paid_cents, policy_version)
      VALUES ('legacy', 'guest', 'hotel', '2027-01-01', '2029-06-01', '2029-06-02',
        'flexible', 'active', 7, ?, 2000, 400, 290, 180, 110, 'flex-30')
      """,
      [Jason.encode!(Enum.map(rooms, &Jason.encode!/1))]
    )

    for {id, expiry} <- [{1, "2029-12-31"}, {2, "2028-12-31"}] do
      Repo.query!(
        "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (?, 'guest', ?, 10, ?)",
        [id, "lot-#{id}", expiry]
      )
    end

    for {lot, amount} <- [{1, 40}, {2, 30}, {2, 20}, {1, 20}] do
      Repo.query!(
        "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('legacy', ?, ?)",
        [lot, amount]
      )
    end

    for {id, type, amount, date, status} <- [
          {"credit", "apply_hotel_credit", 40, "2027-04-01", "applied"},
          {"z-cash", "record_cash_payment", 100, "2027-03-01", "applied"},
          {"rejected", "record_cash_payment", 1000, "2027-01-01", "rejected"},
          {"a-cash", "record_cash_payment", 20, "2027-02-01", "applied"}
        ] do
      submission = %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "legacy",
        "amount_cents" => amount,
        "occurred_on" => date
      }

      result = %{
        "operation_id" => id,
        "status" => status,
        "group_id" => "legacy",
        "amount_cents" => amount
      }

      Repo.query!("INSERT INTO operations (operation_id, submission, result) VALUES (?, ?, ?)", [
        id,
        Jason.encode!(submission),
        Jason.encode!(result)
      ])
    end

    audit = Repo.all(Operation)

    assert migrate() == [
             20_260_905_000_300,
             20_260_905_000_400,
             20_260_905_000_500,
             20_260_905_000_600
           ]

    assert migrate() == []
    assert Repo.all(Operation) == audit
    group = Reservations.get_group("legacy")
    assert group.revision == 7

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {60, 40},
             {30, 70},
             {90, 0},
             {0, 0}
           ]

    assert %{cash_held_cents: 180, credit_liability_cents: 130} =
             Reservations.ledger(~D[2027-01-01])

    assert [%{refunded_cents: 0, credit_issued_cents: 99}] =
             Reservations.apply_batch([
               payment(%{
                 "operation_id" => "settle-legacy",
                 "type" => "cancel_rooms",
                 "group_id" => "legacy",
                 "room_ids" => ["r1", "r0"],
                 "occurred_on" => "2027-04-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert {:ok, %{held_cents: 70, converted_to_credit_cents: 30}} =
             Reservations.get_payment("z-cash")

    assert [%{charged_back_cents: 100, revision: 9}] =
             Reservations.apply_batch([
               %{
                 "operation_id" => "charge",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "z-cash",
                 "occurred_on" => "2027-04-01"
               }
             ])

    assert Repo.get_by!(CreditLot, source_operation_id: "settle-legacy").remaining_cents == 66

    assert Enum.map(Reservations.get_group("legacy").rooms, & &1["cash_paid_cents"]) == [
             0,
             0,
             20,
             0
           ]

    assert Reservations.get_payment("unattributed") == {:error, "operation_not_found"}
  end

  test "upgrade reconciles historical converted payments and preserves senior bonus entitlement" do
    Reservations.apply_batch([
      opening(),
      payment(%{"operation_id" => "legacy-pay", "amount_cents" => 5}),
      payment(%{"operation_id" => "first", "amount_cents" => 5}),
      payment(%{"operation_id" => "second", "amount_cents" => 5}),
      payment(%{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "refund_method" => "hotel_credit"
      }),
      Map.put(opening(), "group_id", "target"),
      payment(%{
        "operation_id" => "redeem",
        "type" => "apply_hotel_credit",
        "group_id" => "target",
        "amount_cents" => 8
      })
    ])

    Repo.delete_all(from o in Operation, where: o.operation_id == "legacy-pay")
    before = Reservations.ledger(~D[2026-01-02])
    Ecto.Migrator.run(Repo, @migrations, :down, step: 4, log: false)

    assert migrate() == [
             20_260_905_000_300,
             20_260_905_000_400,
             20_260_905_000_500,
             20_260_905_000_600
           ]

    assert Reservations.ledger(~D[2026-01-02]) == before

    assert {:ok, %{recorded_cents: 5, held_cents: 0, converted_to_credit_cents: 5}} =
             Reservations.get_payment("first")

    for {payment, balance} <- [{"first", 4}, {"second", 0}] do
      assert [%{charged_back_cents: 5}] =
               Reservations.apply_batch([
                 %{
                   "operation_id" => "cb-#{payment}",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => payment,
                   "occurred_on" => "2026-01-03"
                 }
               ])

      assert Reservations.guest_credit("guest", ~D[2026-01-03]).available_cents == balance
    end

    assert %{
             credit_liability_cents: 8,
             credit_shortfall_cents: 2,
             cash_converted_to_credit_cents: 5,
             cash_charged_back_cents: 10
           } = Reservations.ledger(~D[2026-01-03])

    assert Reservations.get_group("target").revision == 2
  end

  test "concurrent reductions and chargebacks have at-most-once effects and survive restarts", %{
    repo: repo,
    options: options
  } do
    pay = payment(%{"operation_id" => "pay", "amount_cents" => 2000})
    [_, original] = Reservations.apply_batch([opening(), pay])

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 1000,
      "occurred_on" => "2026-01-03"
    }

    assert [%{revision: 3, amount_cents: 1000}] = Enum.uniq(concurrently(repo, reduction, true))

    charge = %{
      "operation_id" => "charge",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay",
      "occurred_on" => "2026-01-03"
    }

    assert [%{revision: 4, charged_back_cents: 1000}] =
             Enum.uniq(concurrently(repo, charge, true))

    statement = Reservations.get_payment("pay")
    ledger = Reservations.ledger()

    assert {:ok,
            %{recorded_cents: 2000, reduced_cents: 1000, charged_back_cents: 1000, held_cents: 0}} =
             statement

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.get_payment("pay") == statement
    assert Reservations.ledger() == ledger
    assert Reservations.apply_batch([pay]) == [original]
  end

  test "failed chargeback audit rolls back cash and credit clawback together" do
    create_credit()

    before =
      {Repo.all(Group), Repo.all(CreditLot), Repo.all(GroupStay.CashAllocation),
       Repo.all(GroupStay.CreditEntitlement)}

    [pay] =
      Repo.all(
        from o in Operation,
          where: fragment("json_extract(?, '$.type')", o.submission) == "record_cash_payment"
      )

    op = %{
      "operation_id" => "fault-cb",
      "type" => "charge_back_payment",
      "payment_operation_id" => pay.operation_id,
      "occurred_on" => "2026-01-03"
    }

    Repo.query!(
      "CREATE TRIGGER fail_charge BEFORE INSERT ON operations WHEN NEW.operation_id = 'fault-cb' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    assert_raise Exqlite.Error, fn -> Reservations.apply_batch([op]) end

    assert {Repo.all(Group), Repo.all(CreditLot), Repo.all(GroupStay.CashAllocation),
            Repo.all(GroupStay.CreditEntitlement)} == before

    assert Reservations.get_operation("fault-cb") == nil
    Repo.query!("DROP TRIGGER fail_charge")
    assert [%{charged_back_cents: 2000}] = Reservations.apply_batch([op])
  end

  defp transfer(fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "persistent",
        "destination_group_id" => "destination",
        "amount_cents" => 1000,
        "occurred_on" => "2026-01-03"
      },
      fields
    )
  end

  test "concurrent transfer retries survive restart with provenance and original results", %{
    repo: repo,
    options: options
  } do
    pay = payment(%{"operation_id" => "pay"})

    [_, original, _] =
      Reservations.apply_batch([opening(), pay, Map.put(opening(), "group_id", "destination")])

    move = transfer(%{"expected_revision" => 2, "destination_expected_revision" => 1})

    assert [%{source_revision: 3, destination_revision: 2} = result] =
             Enum.uniq(concurrently(repo, move, true))

    ledger = Reservations.ledger()

    assert {:ok,
            %{
              held_by_group: [
                %{group_id: "destination", amount_cents: 1000},
                %{group_id: "persistent", amount_cents: 1000}
              ]
            }} = statement = Reservations.get_payment("pay")

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert migrate() == []
    assert Reservations.apply_batch([move, pay]) == [result, original]
    assert Reservations.get_payment("pay") == statement
    assert Reservations.ledger() == ledger

    assert [%{revision: 4}] =
             Reservations.apply_batch([
               payment(%{
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 500
               })
             ])

    assert Reservations.get_group("destination").cash_paid_cents == 500
    assert Reservations.get_group("destination").revision == 3
  end

  test "competing transfers cannot overdraw a source or overfill a destination", %{repo: repo} do
    Reservations.apply_batch([
      opening(),
      payment(),
      Map.put(opening(), "group_id", "destination")
    ])

    results = concurrently(repo, transfer())
    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_held_funding")) == 6
    assert Reservations.get_group("persistent").cash_paid_cents == 0
    assert Reservations.get_group("destination").cash_paid_cents == 2000

    # Eight distinct sources contend for the same remaining destination capacity.
    for index <- 1..8 do
      Reservations.apply_batch([
        Map.put(opening(), "group_id", "source-#{index}"),
        payment(%{"group_id" => "source-#{index}"})
      ])
    end

    results =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Reservations.apply_batch([
            transfer(%{
              "operation_id" => "compete-#{index}",
              "source_group_id" => "source-#{index}"
            })
          ])
          |> hd()
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.count(results, &(&1.status == "applied")) == 2
    assert Enum.count(results, &(Map.get(&1, :code) == "transfer_exceeds_outstanding")) == 6
    assert Reservations.get_group("destination").cash_paid_cents == 4000
    assert Reservations.get_group("destination").revision == 5
  end

  test "failed transfer audit rolls back both groups, allocation order, and payment participation" do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "source"),
      Map.put(opening(), "group_id", "destination"),
      payment(%{"group_id" => "source", "type" => "apply_hotel_credit", "amount_cents" => 500}),
      payment(%{"group_id" => "source", "operation_id" => "cash"})
    ])

    snapshot = fn ->
      {Repo.all(Group), Repo.all(GroupStay.CashAllocation), Repo.all(CreditAllocation),
       Repo.all(CreditLot), Repo.query!("SELECT value FROM allocation_sequence").rows,
       Reservations.get_payment("cash")}
    end

    before = snapshot.()
    move = transfer(%{"source_group_id" => "source", "amount_cents" => 2200})

    Repo.query!(
      "CREATE TRIGGER fail_transfer BEFORE INSERT ON operations WHEN NEW.operation_id = 'transfer' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    assert_raise Exqlite.Error, fn -> Reservations.apply_batch([move]) end
    assert snapshot.() == before
    assert Reservations.get_operation("transfer") == nil
    Repo.query!("DROP TRIGGER fail_transfer")
    assert [%{source_revision: 4, destination_revision: 2}] = Reservations.apply_batch([move])
    assert Reservations.get_group("destination").cash_paid_cents == 2000
    assert Reservations.get_group("destination").credit_paid_cents == 200
  end

  test "transfer upgrade recovers mixed legacy and recorded funding order without changing balances" do
    create_credit()

    Reservations.apply_batch([
      Map.put(opening(), "group_id", "source"),
      Map.put(opening(), "group_id", "destination"),
      payment(%{"group_id" => "source", "operation_id" => "legacy-cash", "amount_cents" => 40}),
      payment(%{
        "group_id" => "source",
        "operation_id" => "legacy-credit",
        "type" => "apply_hotel_credit",
        "amount_cents" => 30
      }),
      payment(%{
        "group_id" => "source",
        "operation_id" => "z-cash",
        "amount_cents" => 50,
        "occurred_on" => "2026-03-01"
      }),
      payment(%{
        "group_id" => "source",
        "operation_id" => "credit",
        "type" => "apply_hotel_credit",
        "amount_cents" => 40,
        "occurred_on" => "2026-02-01"
      }),
      payment(%{
        "group_id" => "source",
        "operation_id" => "a-cash",
        "amount_cents" => 20,
        "occurred_on" => "2026-01-01"
      })
    ])

    Repo.delete_all(
      from o in Operation, where: o.operation_id in ["legacy-cash", "legacy-credit"]
    )

    Repo.query!(
      "UPDATE cash_allocations SET payment_operation_id = NULL WHERE payment_operation_id = 'legacy-cash'"
    )

    Repo.query!(
      "UPDATE credit_allocations SET operation_id = NULL WHERE operation_id = 'legacy-credit'"
    )

    before =
      {Repo.all(Group), Repo.all(CreditLot), Reservations.ledger(~D[2026-03-01]),
       Repo.all(Operation)}

    Ecto.Migrator.run(Repo, @migrations, :down, step: 3, log: false)
    assert migrate() == [20_260_905_000_400, 20_260_905_000_500, 20_260_905_000_600]
    assert migrate() == []

    assert {Repo.all(Group), Repo.all(CreditLot), Reservations.ledger(~D[2026-03-01]),
            Repo.all(Operation)} == before

    assert {:ok, statement} = Reservations.get_payment("z-cash")
    refute Map.has_key?(statement, :held_by_group)
    Reservations.apply_batch([transfer(%{"source_group_id" => "source", "amount_cents" => 120})])
    assert %{cash_paid_cents: 70, credit_paid_cents: 50} = Reservations.get_group("destination")
    assert %{cash_paid_cents: 40, credit_paid_cents: 20} = Reservations.get_group("source")
    assert Reservations.ledger(~D[2026-03-01]) == elem(before, 2)
    # Moving the final senior cash block must preserve its lack of payment identity.
    Reservations.apply_batch([
      transfer(%{
        "operation_id" => "legacy-move",
        "source_group_id" => "source",
        "amount_cents" => 60
      })
    ])

    assert [%{payment_operation_id: nil, amount_cents: 40}] =
             Repo.all(
               from a in GroupStay.CashAllocation,
                 where: a.group_id == "destination" and is_nil(a.payment_operation_id)
             )

    assert Reservations.get_payment("legacy-cash") == {:error, "operation_not_found"}
  end
end
