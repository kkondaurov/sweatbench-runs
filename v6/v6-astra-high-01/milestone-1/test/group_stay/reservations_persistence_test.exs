defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}

  @migrations [{20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups}]

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("priv/repo/migrations/20260905000000_create_groups.exs")
    end

    :ok
  end

  setup do
    directory = Path.expand("tmp/reservations-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 10_000
    ]

    # Initialize SQLite with one connection before exercising a real connection pool.
    pid = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(pid)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    pid = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(pid)
    %{repo: pid, options: options}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
    }
  end

  defp payment(fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group",
        "amount_cents" => 50
      },
      fields
    )
  end

  defp concurrent(repo, operation) do
    1..8
    |> Task.async_stream(
      fn id ->
        Repo.put_dynamic_repo(repo)
        [result] = Reservations.submit([Map.put(operation, "operation_id", "op-#{id}")])
        result
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "migrations are repeatable and reservation accounting survives repository restart", %{
    options: options
  } do
    assert [%{status: "applied"}, %{status: "applied"}] =
             Reservations.submit([opening(), payment()])

    assert [%{status: "rejected"}, %{status: "applied"}] =
             Reservations.submit([
               payment(),
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group"
               }
             ])

    group = Reservations.get_group("group")
    ledger = Reservations.ledger()
    assert ledger == %{cash_held_cents: 0, cash_refunded_cents: 50, cash_retained_cents: 0}

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group") == group
    assert Reservations.ledger() == ledger
  end

  test "concurrent operations can consume a revision only once", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment(%{"amount_cents" => 1, "expected_revision" => 1}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group").revision == 2
    assert Reservations.ledger().cash_held_cents == 1
  end

  test "concurrent unconditional payments cannot overfund a deposit", %{repo: repo} do
    Reservations.submit([opening()])
    results = concurrent(repo, payment())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.get_group("group").outstanding_deposit_cents == 10
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "concurrent duplicate openings create exactly one group", %{repo: repo} do
    results = concurrent(repo, opening())
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group").revision == 1
  end

  test "concurrent cancellations settle cash only once", %{repo: repo} do
    Reservations.submit([opening(), payment()])

    results =
      concurrent(repo, %{
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group"
      })

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_not_active")) == 7
    assert Reservations.get_group("group").revision == 3

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 50,
             cash_retained_cents: 0
           }
  end
end
