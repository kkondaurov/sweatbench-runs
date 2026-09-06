defmodule GroupStay.ReservationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  setup_all do
    directory =
      Path.expand("../../tmp/concurrency-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    # Real, independent connection pools exercise SQLite locking outside the SQL sandbox.
    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    first = start_supervised!({Repo, options}, id: :first_repo)
    Repo.put_dynamic_repo(first)

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    second = start_supervised!({Repo, options}, id: :second_repo)

    opening = %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "concurrent",
      "guest_id" => "guest",
      "property_id" => "property",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }

    %{repos: [first, second], opening: opening}
  end

  setup %{repos: [first | _]} do
    Repo.put_dynamic_repo(first)
    Repo.delete_all(GroupStay.Group)
    :ok
  end

  defp race(repos, operation) do
    parent = self()

    tasks =
      for repo <- repos do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.submit([operation]) |> hd()
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _}, 1000
    end

    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  test "simultaneous opens preserve group uniqueness", %{repos: repos, opening: opening} do
    results = race(repos, opening)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 1
    assert Reservations.get_group("concurrent").revision == 1
  end

  test "only one concurrent writer can use a revision", %{repos: repos, opening: opening} do
    Reservations.submit([opening])

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "concurrent",
      "occurred_on" => "2026-10-02",
      "amount_cents" => 50,
      "expected_revision" => 1
    }

    results = race(repos, payment)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 1
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "unconditional concurrent payments cannot overfund a deposit", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([opening])

    results =
      race(repos, %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-02",
        "amount_cents" => 150
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 1
    assert Reservations.get_group("concurrent").outstanding_deposit_cents == 50
    assert Reservations.ledger().cash_held_cents == 150
  end

  test "migrations can be rerun on a populated database without losing records", %{
    opening: opening
  } do
    Reservations.submit([opening])
    before = Reservations.get_group("concurrent")

    assert Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
             all: true,
             log: false
           ) == []

    assert Reservations.get_group("concurrent") == before
  end
end
