defmodule GroupStay.DurableStorageTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Operation, Repo, Reservations}
  import Ecto.Query

  defmodule StorageRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    path = Path.expand("_build/durable-#{System.unique_integer([:positive])}.db")
    opts = [database: path, pool_size: 2, busy_timeout: 10_000]
    start_supervised!({StorageRepo, Keyword.put(opts, :pool_size, 1)})

    Ecto.Migrator.run(StorageRepo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    stop_supervised!(StorageRepo)
    start_supervised!({StorageRepo, opts})
    previous = Repo.put_dynamic_repo(StorageRepo)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    %{opts: opts}
  end

  defp opening do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2026-10-01",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1000}]
    }
  end

  defp payment(id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "group_id" => "group",
      "occurred_on" => "2026-10-02",
      "amount_cents" => amount
    }
  end

  test "independent connections serialize simultaneous retries and conflicts" do
    operations = List.duplicate(opening(), 8)
    results = concurrent(operations)
    assert Enum.uniq(results) |> length() == 1
    assert [%{status: "applied", revision: 1}] = hd(results)
    results = concurrent(List.duplicate(payment("pay", 100), 8))
    assert Enum.uniq(results) |> length() == 1
    assert Reservations.get("group").cash_paid_cents == 100
    assert Reservations.get("group").revision == 2

    results = concurrent([payment("race", 10), payment("race", 20)]) |> List.flatten()
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 1
    assert Reservations.get("group").revision == 3
    assert Repo.aggregate(Operation, :count) == 3
  end

  defp concurrent(ops) do
    parent = self()

    tasks =
      Enum.map(ops, fn op ->
        Task.async(fn ->
          Repo.put_dynamic_repo(StorageRepo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.batch([op])
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _}, 5000)
    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await(&1, 20_000))
  end

  test "stored results and audit order survive all database connections restarting", %{opts: opts} do
    rejected = payment("missing", 1) |> Map.put("group_id", "missing")
    operations = [opening(), rejected, payment("pay", 100)]
    results = Reservations.batch(operations)
    records = Repo.all(from o in Operation, order_by: o.id)
    stop_supervised!(StorageRepo)
    start_supervised!({StorageRepo, opts})
    assert Reservations.batch(operations) == results
    assert Repo.all(from o in Operation, order_by: o.id) == records
    assert Reservations.get("group").revision == 2
    assert Reservations.operation("pay")["revision"] == 2
  end

  test "unexpected failure after domain writes rolls back that operation and aborts the batch" do
    # Fail at audit insertion, after a payment has already updated its group.
    StorageRepo.query!("""
    CREATE TRIGGER fail_audit BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END
    """)

    assert_raise Exqlite.Error, fn ->
      Reservations.batch([opening(), payment("fault", 100), payment("later", 50)])
    end

    assert Reservations.get("group").revision == 1
    assert Reservations.get("group").cash_paid_cents == 0
    assert Reservations.operation("open")["status"] == "applied"
    assert Reservations.operation("fault") == nil
    assert Reservations.operation("later") == nil

    StorageRepo.query!("DROP TRIGGER fail_audit")

    assert [%{revision: 1}, %{revision: 2}, %{revision: 3}] =
             Reservations.batch([opening(), payment("fault", 100), payment("later", 50)])

    assert Reservations.get("group").cash_paid_cents == 150
  end
end
