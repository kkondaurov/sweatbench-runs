defmodule GroupStay.DurableOperationsTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations, Operation}

  setup do
    path = Path.expand("_build/durable-#{System.unique_integer([:positive])}.db")

    options = [
      name: :durable_operations_repo,
      database: path,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 2_000
    ]

    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous = Repo.put_dynamic_repo(:durable_operations_repo)
    Ecto.Migrator.run(Repo, Path.expand("priv/repo/migrations"), :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
    end)

    %{options: options}
  end

  test "independent connections serialize retries and retain outcomes after repo restart", %{
    options: options
  } do
    opening = %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2026-01-01",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 10000}]
    }

    [opened] = Reservations.batch([opening])

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "group",
      "occurred_on" => "2026-01-01",
      "amount_cents" => 100,
      "expected_revision" => 1
    }

    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(:durable_operations_repo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.batch([payment])
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    results = Enum.map(tasks, &Task.await(&1, 20_000))
    assert [[%{"status" => "applied", "revision" => 2}]] = Enum.uniq(results)
    rejected = Map.put(payment, "operation_id", "stale")
    [stale] = Reservations.batch([rejected])
    assert stale["actual_revision"] == 2
    assert Repo.aggregate(Operation, :count) == 3
    assert Reservations.ledger().cash_held_cents == 100
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Reservations.batch([opening, payment, rejected]) == [opened, hd(hd(results)), stale]
    assert Reservations.get_operation("pay") == hd(hd(results))
    assert Reservations.get_group("group").revision == 2
    assert Repo.aggregate(Operation, :count) == 3

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 40,
      "expected_revision" => 2,
      "occurred_on" => "2026-01-02"
    }

    reduced = concurrently(reduction)
    assert reduced["revision"] == 3
    assert Reservations.ledger().cash_reduced_cents == 40
    assert {:ok, statement} = Reservations.get_payment("pay")
    assert statement["held_cents"] == 60
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Reservations.batch([reduction, payment]) == [reduced, hd(hd(results))]
    assert Reservations.get_group("group").revision == 3

    cancellation = %{
      "operation_id" => "cancel",
      "type" => "cancel_rooms",
      "group_id" => "group",
      "room_ids" => ["a"],
      "expected_revision" => 3,
      "occurred_on" => "2026-01-03",
      "refund_method" => "hotel_credit"
    }

    cancelled = concurrently(cancellation)
    assert cancelled["credit_issued_cents"] == 66
    assert Reservations.ledger(~D[2026-01-03]).credit_liability_cents == 66

    chargeback = %{
      "operation_id" => "charge",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay",
      "expected_revision" => 4,
      "occurred_on" => "2026-01-04"
    }

    charged = concurrently(chargeback)
    assert charged["charged_back_cents"] == 60
    assert charged["revision"] == 5
    stop_supervised!(Repo)
    start_supervised!({Repo, options})

    assert Reservations.batch([payment, reduction, cancellation, chargeback]) == [
             hd(hd(results)),
             reduced,
             cancelled,
             charged
           ]

    assert Reservations.get_group("group").revision == 5
    assert Reservations.ledger(~D[2026-01-04]).credit_liability_cents == 0
    assert {:ok, statement} = Reservations.get_payment("pay")
    assert statement["charged_back_cents"] == 60
    assert statement["reduced_cents"] == 40
    assert statement["held_cents"] == 0
  end

  defp concurrently(operation) do
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(:durable_operations_repo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.batch([operation])
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    assert [[result]] = tasks |> Enum.map(&Task.await(&1, 20_000)) |> Enum.uniq()
    assert result["status"] == "applied"
    result
  end
end
