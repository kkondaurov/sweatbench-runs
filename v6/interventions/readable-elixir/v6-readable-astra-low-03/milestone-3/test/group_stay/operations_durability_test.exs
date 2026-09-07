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
