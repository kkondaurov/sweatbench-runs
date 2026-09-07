defmodule GroupStay.ConcurrentOperationsTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  # Real connections are essential here: sandbox tasks share one transaction and
  # cannot exercise SQLite's writer locking between independent transactions.
  setup do
    directory = Path.join(File.cwd!(), ".concurrency-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    on_exit(fn -> File.rm_rf!(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool
    ]

    # Initialize the database before opening competing connections so their
    # connection pragmas do not race the initial journal setup.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})

    Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    stop_supervised!(Repo)
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 4)})
    Repo.put_dynamic_repo(repo)
    %{repo: repo}
  end

  test "competing writers cannot both apply the same revision", %{repo: repo} do
    assert [%{revision: 1}] =
             Reservations.submit([
               %{
                 "operation_id" => "open",
                 "type" => "open_group",
                 "group_id" => "concurrent",
                 "guest_id" => "guest",
                 "property_id" => "hotel",
                 "occurred_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 15000}]
               }
             ])

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
                "group_id" => "concurrent",
                "amount_cents" => 100,
                "expected_revision" => 1
              }
            ])

          result
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end
end
