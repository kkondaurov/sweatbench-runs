defmodule GroupStay.OperationsDurabilityTest do
  use ExUnit.Case
  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Operations.Record

  setup do
    directory = Path.join(File.cwd!(), "tmp/operations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()

    on_exit(fn ->
      if Process.alive?(test_supervisor), do: Supervisor.stop(test_supervisor)
      GroupStay.DatabaseFiles.remove_directory!(directory)
    end)

    options = [
      name: nil,
      database: Path.join(directory, "durable.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 50
    ]

    pid = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(pid)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)

    Ecto.Migrator.run(Repo, Path.join(File.cwd!(), "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    stop_supervised!(Repo)
    concurrent_repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(concurrent_repo)
    %{repo: concurrent_repo, options: options}
  end

  test "reporting inception and journal survive database restart", %{options: options} do
    start = %{
      "operation_id" => "finance-start",
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-01",
      "starts_on" => "2026-10-01"
    }

    open = %{
      "operation_id" => "finance-open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "finance-group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }

    payment = %{
      "operation_id" => "finance-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-01",
      "group_id" => "finance-group",
      "amount_cents" => 100
    }

    [result, _, paid] = Reservations.submit([start, open, payment])
    {:ok, report} = GroupStay.Finance.daily_report("2026-10-01")
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([start, payment]) == [result, paid]
    assert GroupStay.Finance.daily_report("2026-10-01") == {:ok, report}

    assert [%{"code" => "reporting_already_started"}] =
             Reservations.submit([Map.put(start, "operation_id", "another-start")])
  end

  @tag capture_log: true
  test "independent connections serialize retries and durable outcomes survive repo restart", %{
    repo: repo,
    options: options
  } do
    open = %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 10000}]
    }

    [opened] = Reservations.submit([open])

    pay = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "g",
      "amount_cents" => 100,
      "occurred_on" => "2027-02-01",
      "expected_revision" => 1
    }

    tasks =
      for _ <- 1..12 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          submit_with_gateway_retry(pay)
        end)
      end

    results = Task.await_many(tasks, 20_000)
    assert [paid] = hd(results)
    assert paid["revision"] == 2
    assert Enum.uniq(results) == [[paid]]
    stale_op = Map.put(pay, "operation_id", "stale")
    [stale] = Reservations.submit([stale_op])
    assert stale["actual_revision"] == 2
    assert Reservations.get_group("g").cash_paid_cents == 100
    assert Repo.aggregate(Record, :count) == 3

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([open, pay, stale_op]) == [opened, paid, stale]
    assert Operations.get_result("pay") == paid
    assert Reservations.get_group("g").revision == 2
    assert Repo.aggregate(Record, :count) == 3
  end

  @tag capture_log: true
  test "concurrent room settlements and corrections commit once and survive restart", %{
    repo: repo,
    options: options
  } do
    open = %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ]
    }

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "g",
      "amount_cents" => 200,
      "occurred_on" => "2026-01-01"
    }

    [_, original] = Reservations.submit([open, payment])

    operations =
      [
        %{
          "operation_id" => "reduce",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "pay",
          "amount_cents" => 20
        },
        %{
          "operation_id" => "cancel",
          "type" => "cancel_rooms",
          "group_id" => "g",
          "room_ids" => ["a"],
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "charge",
          "type" => "charge_back_payment",
          "payment_operation_id" => "pay"
        }
      ]
      |> Enum.map(&Map.put(&1, "occurred_on", "2026-10-01"))

    results =
      Enum.map(operations, fn operation ->
        tasks =
          for _ <- 1..8 do
            Task.async(fn ->
              Repo.put_dynamic_repo(repo)
              submit_with_gateway_retry(operation)
            end)
          end

        results = Task.await_many(tasks, 20_000)
        assert length(Enum.uniq(results)) == 1
        hd(hd(results))
      end)

    assert Enum.map(results, & &1["revision"]) == [3, 4, 5]
    assert {:ok, statement} = GroupStay.Accounting.statement("pay")
    assert statement.reduced_cents == 20
    assert statement.charged_back_cents == 180
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 0
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit(operations) == results
    assert Reservations.submit([payment]) == [original]
    assert GroupStay.Accounting.statement("pay") == {:ok, statement}
    assert Reservations.get_group("g").revision == 5
  end

  @tag capture_log: true
  test "concurrent transfers commit once and preserve statements after restart", %{
    repo: repo,
    options: options
  } do
    Reservations.submit([
      transfer_group("s"),
      transfer_group("d"),
      transfer_operation("pay", "record_cash_payment", %{"group_id" => "s", "amount_cents" => 200})
    ])

    transfer =
      transfer_operation("move", "transfer_deposit", %{
        "source_group_id" => "s",
        "destination_group_id" => "d",
        "amount_cents" => 150,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    results =
      for _ <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          submit_with_gateway_retry(transfer)
        end)
      end
      |> Task.await_many(20_000)

    assert [[result]] = Enum.uniq(results)
    assert result["source_revision"] == 3
    assert result["destination_revision"] == 2
    assert {:ok, statement} = GroupStay.Accounting.statement("pay")

    assert statement.held_by_group == [
             %{group_id: "d", amount_cents: 150},
             %{group_id: "s", amount_cents: 50}
           ]

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([transfer]) == [result]
    assert GroupStay.Accounting.statement("pay") == {:ok, statement}
    assert Reservations.ledger().cash_held_cents == 200
  end

  test "upgrade reconstructs interleaved allocations after cancellation and refilling" do
    Reservations.submit([
      transfer_group("seed"),
      transfer_operation("seed-pay", "record_cash_payment", %{
        "group_id" => "seed",
        "amount_cents" => 200
      }),
      transfer_operation("seed-cancel", "cancel_group", %{
        "group_id" => "seed",
        "refund_method" => "hotel_credit"
      }),
      transfer_group("s"),
      transfer_group("d"),
      transfer_operation("pay", "record_cash_payment", %{"group_id" => "s", "amount_cents" => 50}),
      transfer_operation("credit", "apply_hotel_credit", %{
        "group_id" => "s",
        "amount_cents" => 120
      }),
      transfer_operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 40
      }),
      transfer_operation("credit2", "apply_hotel_credit", %{
        "group_id" => "s",
        "amount_cents" => 30
      }),
      transfer_operation("partial", "cancel_rooms", %{"group_id" => "s", "room_ids" => ["b"]}),
      transfer_operation("pay2", "record_cash_payment", %{"group_id" => "s", "amount_cents" => 10})
    ])

    before = Reservations.get_group("s")
    ledger = Reservations.ledger(~D[2026-10-01])
    migrations = Path.join(File.cwd!(), "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    assert Reservations.get_group("s") == before
    assert Reservations.ledger(~D[2026-10-01]) == ledger

    [result] =
      Reservations.submit([
        transfer_operation("move", "transfer_deposit", %{
          "source_group_id" => "s",
          "destination_group_id" => "d",
          "amount_cents" => 50
        })
      ])

    assert result["status"] == "applied"
    assert Reservations.get_group("d").cash_paid_cents == 10
    assert Reservations.get_group("d").credit_paid_cents == 40
    assert Reservations.get_group("s").cash_paid_cents == 10
    assert Reservations.get_group("s").credit_paid_cents == 40
  end

  defp transfer_group(id) do
    transfer_operation("open-" <> id, "open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ]
    })
  end

  defp transfer_operation(id, type, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2026-10-01"}, attrs)
  end

  # Contending SQLite writers may time out before acquiring their transaction.
  # Model the gateway retrying that server failure with the same operation ID.
  defp submit_with_gateway_retry(operation, attempts \\ 30) do
    Reservations.submit([operation])
  rescue
    error in Exqlite.Error ->
      if attempts > 1 && error.message == "database is locked" &&
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep(10)
        submit_with_gateway_retry(operation, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
