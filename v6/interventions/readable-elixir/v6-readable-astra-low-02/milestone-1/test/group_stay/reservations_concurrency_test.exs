defmodule GroupStay.ReservationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  setup do
    # A real connection pool exercises SQLite locking outside Sandbox's shared
    # test transaction. Keep this disposable database inside the repository.
    directory =
      Path.expand("../../tmp/concurrency-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool
    ]

    # Initialize WAL and migrate before opening competing connections.
    bootstrap = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(bootstrap)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    stop_supervised!(Repo)

    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      File.rm_rf!(directory)
    end)

    %{repo: repo}
  end

  @tag capture_log: true
  test "competing writers cannot both consume the same revision", %{repo: repo} do
    opening = %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "shared",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }

    assert [%{status: "applied"}] = Reservations.submit([opening])

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Repo.put_dynamic_repo(repo)

          [result] =
            Reservations.submit([
              %{
                "operation_id" => "payment-#{index}",
                "type" => "record_cash_payment",
                "occurred_on" => "2026-10-04",
                "group_id" => "shared",
                "amount_cents" => 100,
                "expected_revision" => 1
              }
            ])

          result
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("shared").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end
end
