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
end
