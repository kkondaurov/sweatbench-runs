defmodule GroupStay.DurableStorageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record
  @endpoint GroupStayWeb.Endpoint

  setup do
    directory = Path.expand("tmp/durable-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "operations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 100
    ]

    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      Repo.put_dynamic_repo(previous)
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    %{repo: repo, options: options}
  end

  defp open do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }
  end

  defp payment(id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "group_id" => "group",
      "occurred_on" => "2027-01-01",
      "amount_cents" => amount,
      "expected_revision" => 1
    }
  end

  @tag :capture_log
  test "simultaneous retries across database connections apply once", %{repo: repo} do
    [opened] = Operations.process_batch([open()])
    submitted = payment("pay", 100)

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(repo)

          try do
            Operations.process_batch([submitted])
          rescue
            error in Exqlite.Error ->
              # A bounded SQLite lock wait may become HTTP 500. The gateway
              # retries that attempt after the contending transactions finish.
              assert error.message in ["database is locked", "Database busy"]
              :retry
          end
        end,
        max_concurrency: 12,
        timeout: 20_000
      )
      |> Enum.map(fn
        {:ok, [result]} -> result
        {:ok, :retry} -> :retry
      end)

    results =
      Enum.map(results, fn
        :retry ->
          [result] = Operations.process_batch([submitted])
          result

        result ->
          result
      end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "pay",
               "status" => "applied",
               "group_id" => "group",
               "amount_cents" => 100,
               "outstanding_deposit_cents" => 1900,
               "revision" => 2
             }
           ]

    assert Reservations.get_group("group").deposit_paid_cents == 100
    assert Repo.aggregate(Record, :count) == 2
    assert Operations.get_result("open") == opened
  end

  test "results and audit order survive stopping and reopening the database", %{options: options} do
    operations = [open(), payment("pay", 100), payment("stale", 50)]
    results = Operations.process_batch(operations)
    records = Repo.all(from r in Record, order_by: r.id)
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert Operations.process_batch(operations) == results
    assert Repo.all(from r in Record, order_by: r.id) == records
    assert Reservations.get_group("group").revision == 2
    stop_supervised!(Repo)
  end

  test "audit write fault rolls back domain changes, aborts HTTP batch and permits retry" do
    Repo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'pay'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    submitted = [open(), payment("pay", 100), payment("later", 50)]

    assert_error_sent 500, fn ->
      build_conn() |> post("/api/v1/partner-batches", %{"operations" => submitted})
    end

    assert Reservations.get_group("group").revision == 1
    assert Reservations.get_group("group").deposit_paid_cents == 0
    assert Operations.get_result("open")["status"] == "applied"
    assert Operations.get_result("pay") == nil
    assert Operations.get_result("later") == nil

    Repo.query!("DROP TRIGGER fail_audit")
    assert [opened, paid, stale] = Operations.process_batch(submitted)
    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert stale["code"] == "stale_revision"
    assert Repo.aggregate(Record, :count) == 3
  end

  test "chargeback cash and clawback commit with the inbox and survive restart", %{
    options: options
  } do
    cancel = %{
      "operation_id" => "cancel",
      "type" => "cancel_group",
      "group_id" => "group",
      "occurred_on" => "2027-01-01",
      "refund_method" => "hotel_credit"
    }

    target = open() |> Map.merge(%{"operation_id" => "target", "group_id" => "target"})

    credit = %{
      "operation_id" => "credit",
      "type" => "apply_hotel_credit",
      "group_id" => "target",
      "occurred_on" => "2027-01-01",
      "amount_cents" => 80
    }

    Operations.process_batch([open(), payment("pay", 100), cancel, target, credit])
    before = Reservations.ledger(~D[2027-01-01])

    charge = %{
      "operation_id" => "charge",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay",
      "occurred_on" => "2027-01-01"
    }

    Repo.query!("""
    CREATE TRIGGER fail_charge BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'charge'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Operations.process_batch([charge]) end
    assert Reservations.ledger(~D[2027-01-01]) == before
    assert Reservations.get_group("group").revision == 3
    assert {:ok, %{converted_to_credit_cents: 100}} = GroupStay.Payments.statement("pay")
    assert Operations.get_result("charge") == nil
    Repo.query!("DROP TRIGGER fail_charge")
    [result] = Operations.process_batch([charge])
    after_charge = Reservations.ledger(~D[2027-01-01])
    assert after_charge.credit_shortfall_cents == 80
    assert after_charge.credit_liability_cents == 80
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Operations.process_batch([charge]) == [result]
    assert Reservations.ledger(~D[2027-01-01]) == after_charge
    assert {:ok, %{charged_back_cents: 100}} = GroupStay.Payments.statement("pay")
    assert Reservations.get_group("target").revision == 2
    stop_supervised!(Repo)
  end

  test "transfer allocations, participation and both revisions roll back together and survive restart",
       %{options: options} do
    destination =
      open() |> Map.merge(%{"operation_id" => "destination", "group_id" => "destination"})

    Operations.process_batch([open(), destination, payment("pay", 100)])

    transfer = %{
      "operation_id" => "transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "group",
      "destination_group_id" => "destination",
      "amount_cents" => 60,
      "occurred_on" => "2027-01-01"
    }

    Repo.query!("""
    CREATE TRIGGER fail_transfer BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'transfer'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    before = Reservations.ledger(~D[2027-01-01])
    assert_raise Exqlite.Error, fn -> Operations.process_batch([transfer]) end
    assert Reservations.get_group("group").revision == 2
    assert Reservations.get_group("group").deposit_paid_cents == 100
    assert Reservations.get_group("destination").revision == 1
    assert Reservations.get_group("destination").deposit_paid_cents == 0
    assert Operations.get_result("transfer") == nil
    assert {:ok, statement} = GroupStay.Payments.statement("pay")
    refute Map.has_key?(statement, :held_by_group)
    Repo.query!("DROP TRIGGER fail_transfer")
    [result] = Operations.process_batch([transfer])
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Operations.process_batch([transfer]) == [result]
    assert Reservations.ledger(~D[2027-01-01]) == before
    assert Reservations.get_group("group").revision == 3
    assert Reservations.get_group("destination").revision == 2

    assert {:ok,
            %{
              held_by_group: [
                %{group_id: "destination", amount_cents: 60},
                %{group_id: "group", amount_cents: 40}
              ]
            }} = GroupStay.Payments.statement("pay")

    stop_supervised!(Repo)
  end

  test "finance inception and movements commit with audit records and survive restart", %{
    options: options
  } do
    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2027-01-01",
      "starts_on" => "2027-01-01"
    }

    Operations.process_batch([open()])

    Repo.query!("""
    CREATE TRIGGER fail_finance_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id IN ('start', 'pay')
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Operations.process_batch([start]) end
    assert GroupStay.Finance.daily_report("2027-01-01") == {:error, "report_not_available"}
    assert Repo.aggregate(GroupStay.Finance.Entry, :count) == 0
    Repo.query!("DROP TRIGGER fail_finance_audit")
    [started] = Operations.process_batch([start])
    {:ok, opening} = GroupStay.Finance.daily_report("2027-01-01")

    Repo.query!("""
    CREATE TRIGGER fail_finance_payment BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'pay'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Operations.process_batch([payment("pay", 100)]) end
    assert GroupStay.Finance.daily_report("2027-01-01") == {:ok, opening}
    assert Reservations.get_group("group").revision == 1
    Repo.query!("DROP TRIGGER fail_finance_payment")
    [paid] = Operations.process_batch([payment("pay", 100)])
    {:ok, report} = GroupStay.Finance.daily_report("2027-01-01")
    entries = Repo.all(from e in GroupStay.Finance.Entry, order_by: e.id)
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Operations.process_batch([start, payment("pay", 100)]) == [started, paid]
    assert GroupStay.Finance.daily_report("2027-01-01") == {:ok, report}
    assert Repo.all(from e in GroupStay.Finance.Entry, order_by: e.id) == entries
    stop_supervised!(Repo)
  end

  @tag :capture_log
  test "concurrent start attempts establish exactly one inception", %{repo: repo} do
    Operations.process_batch([open(), payment("pay", 100)])

    starts =
      for id <- 1..8 do
        %{
          "operation_id" => "start-#{id}",
          "type" => "start_finance_reporting",
          "occurred_on" => "2027-01-01",
          "starts_on" => "2027-01-01"
        }
      end

    starts
    |> Task.async_stream(
      fn operation ->
        Repo.put_dynamic_repo(repo)

        try do
          Operations.process_batch([operation])
        rescue
          error in Exqlite.Error ->
            assert error.message in ["database is locked", "Database busy"]
            :retry
        end
      end,
      max_concurrency: 8,
      timeout: 20_000
    )
    |> Enum.each(fn {:ok, _} -> :ok end)

    results = Operations.process_batch(starts)
    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reporting_already_started")) == 7
    {:ok, report} = GroupStay.Finance.daily_report("2027-01-01")
    assert [cash] = report.cash
    assert cash["opening_held_cents"] == 100
    assert cash["closing_held_cents"] == 100
  end

  test "period close and late postings commit with audit records and survive restart", %{
    options: options
  } do
    start = %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2027-01-01",
      "starts_on" => "2027-01-01"
    }

    close = %{
      "operation_id" => "close",
      "type" => "close_finance_period",
      "occurred_on" => "2027-01-01",
      "period_end_on" => "2027-01-31"
    }

    Operations.process_batch([open(), start, payment("pay", 100)])

    Repo.query!("""
    CREATE TRIGGER fail_close BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'close'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_raise Exqlite.Error, fn -> Operations.process_batch([close]) end
    assert {:ok, %{status: "open"}} = GroupStay.Finance.daily_report("2027-01-01")
    assert Operations.get_result("close") == nil
    Repo.query!("DROP TRIGGER fail_close")

    [closed] = Operations.process_batch([close])
    {:ok, published} = GroupStay.Finance.daily_report("2027-01-01")
    bytes = Jason.encode!(published)
    late = payment("late", 50) |> Map.delete("expected_revision")
    [paid] = Operations.process_batch([late])
    {:ok, open_report} = GroupStay.Finance.daily_report("2027-02-01")
    assert [%{movements: %{"received_cents" => 50}}] = open_report.late_adjustments.cash

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Operations.process_batch([close, late]) == [closed, paid]
    assert GroupStay.Finance.daily_report("2027-02-01") == {:ok, open_report}
    {:ok, reloaded} = GroupStay.Finance.daily_report("2027-01-01")
    assert Jason.encode!(reloaded) == bytes
    Operations.process_batch([payment("later", 25) |> Map.delete("expected_revision")])
    assert GroupStay.Finance.daily_report("2027-01-01") == {:ok, published}
    stop_supervised!(Repo)
  end
end
