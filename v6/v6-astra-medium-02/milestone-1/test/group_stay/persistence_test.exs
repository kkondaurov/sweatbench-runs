defmodule GroupStay.PersistenceTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  setup_all do
    Code.require_file(
      Application.app_dir(:group_stay, "priv/repo/migrations/20260905000000_create_groups.exs")
    )

    :ok
  end

  defp migrate do
    Ecto.Migrator.run(Repo, [{20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups}], :up,
      all: true,
      log: false
    )
  end

  setup do
    File.mkdir_p!("tmp")
    database = Path.expand("tmp/persistence-#{System.unique_integer([:positive])}.db")

    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4
    ]

    # Initialize SQLite's WAL with one connection before opening a concurrent pool.
    initial = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)}, id: :isolated_repo)
    Repo.put_dynamic_repo(initial)
    Repo.query!("SELECT 1")
    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)

    migrate()

    on_exit(fn ->
      for path <- [database, database <> "-wal", database <> "-shm"] do
        assert File.rm(path) in [:ok, {:error, :enoent}]
      end
    end)

    %{repo: pid, options: options}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => "g",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }
  end

  defp payment(id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "record_cash_payment",
        "group_id" => "g",
        "occurred_on" => "2026-09-01",
        "amount_cents" => 150
      },
      extra
    )
  end

  defp race(repo, operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.batch([op]))
          end
        end)
      end)

    for %{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await/1)
  end

  test "concurrent revision checks allow exactly one payment", %{repo: repo} do
    Reservations.batch([opening()])

    results =
      race(repo, [
        payment("one", %{"expected_revision" => 1}),
        payment("two", %{"expected_revision" => 1})
      ])

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "stale_revision" and &1.actual_revision == 2)) == 1
    assert Reservations.get_group("g").revision == 2
    assert Reservations.ledger().cash_held_cents == 150
  end

  test "concurrent unconditional payments cannot overfund", %{repo: repo} do
    Reservations.batch([opening()])
    results = race(repo, [payment("one"), payment("two")])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "payment_exceeds_outstanding")) == 1
    assert Reservations.get_group("g").outstanding_deposit_cents == 50
  end

  test "concurrent opens preserve unique group identifiers", %{repo: repo} do
    results = race(repo, [opening(), %{opening() | "operation_id" => "other"}])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "group_already_exists")) == 1
    assert Reservations.get_group("g").revision == 1
  end

  test "groups and settlements survive repository restart and migration rerun", %{
    options: options
  } do
    Reservations.batch([
      opening(),
      payment("cash"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "group_id" => "g",
        "occurred_on" => "2026-12-01"
      }
    ])

    group = Reservations.get_group("g")
    ledger = Reservations.ledger()
    :ok = stop_supervised(:isolated_repo)
    pid = start_supervised!({Repo, options}, id: :isolated_repo)
    Repo.put_dynamic_repo(pid)

    assert migrate() == []

    assert Reservations.get_group("g") == group
    assert Reservations.ledger() == ledger
    assert ledger == %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 150}
  end
end
