defmodule GroupStay.ReservationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  setup do
    # A real connection pool exercises SQLite locking outside Sandbox's shared
    # test transaction. Keep this disposable database inside the repository.
    directory =
      Path.expand(
        "../../tmp/concurrency-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}",
        __DIR__
      )

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
      GroupStay.DatabaseFiles.remove!(directory)
    end)

    %{repo: repo, database: options[:database]}
  end

  @tag capture_log: true
  test "concurrent retries commit once and replay after the database pool restarts", %{
    repo: repo,
    database: database
  } do
    operation = %{
      "operation_id" => "durable",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "durable-group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10000}]
    }

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(repo)
          Reservations.submit([operation])
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               operation_id: "durable",
               status: "applied",
               group_id: "durable-group",
               revision: 1,
               deposit_due_cents: 6000
             }
           ]

    assert Repo.aggregate(GroupStay.Operations, :count) == 1
    [original] = Enum.uniq(results)

    payment = %{
      "operation_id" => "payment",
      "type" => "record_cash_payment",
      "group_id" => "durable-group",
      "occurred_on" => "2026-10-04",
      "amount_cents" => 100
    }

    payments =
      1..8
      |> Task.async_stream(
        fn _ ->
          Repo.put_dynamic_repo(repo)
          Reservations.submit([payment])
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert [paid] = Enum.uniq(payments)
    assert paid.revision == 2
    assert Reservations.ledger().cash_held_cents == 100

    corrections = [
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "payment",
        "amount_cents" => 20,
        "occurred_on" => "2026-10-04"
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_rooms",
        "group_id" => "durable-group",
        "room_ids" => ["room"],
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-10-04"
      },
      %{
        "operation_id" => "charge",
        "type" => "charge_back_payment",
        "payment_operation_id" => "payment",
        "occurred_on" => "2026-10-04"
      }
    ]

    corrected =
      Enum.map(corrections, fn correction ->
        results =
          1..8
          |> Task.async_stream(
            fn _ ->
              Repo.put_dynamic_repo(repo)
              Reservations.submit([correction])
            end,
            max_concurrency: 8,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, [result]} -> result end)

        assert [result] = Enum.uniq(results)
        assert result.status == "applied"
        result
      end)

    assert Enum.map(corrected, & &1.revision) == [3, 4, 5]
    assert Reservations.ledger().cash_reduced_cents == 20
    assert Reservations.ledger().cash_charged_back_cents == 80
    rejected = Map.merge(operation, %{"operation_id" => "rejected", "type" => "unknown"})
    [rejection] = Reservations.submit([rejected])
    stop_supervised!(Repo)

    restarted =
      start_supervised!(
        {Repo, name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(restarted)
    assert Reservations.submit([operation, payment, rejected]) == [original, paid, rejection]
    assert GroupStay.Operations.get_result("durable") == original
    assert Reservations.submit(corrections) == corrected
    assert Repo.aggregate(GroupStay.Operations, :count) == 6
    assert Reservations.get_group("durable-group").revision == 5
    assert Reservations.ledger().cash_held_cents == 0
    assert Reservations.ledger().cash_charged_back_cents == 80
    assert Reservations.ledger().cash_reduced_cents == 20

    assert {:ok, %{reduced_cents: 20, charged_back_cents: 80}} =
             GroupStay.Reservations.Payments.statement("payment")

    stop_supervised!(Repo)
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
    stop_supervised!(Repo)
  end
end
