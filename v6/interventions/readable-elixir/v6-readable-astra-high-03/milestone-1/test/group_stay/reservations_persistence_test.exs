defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}

  @moduletag :tmp_dir
  @repo_name GroupStay.PersistenceTestRepo
  @migrations [{20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups}]

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("priv/repo/migrations/20260907000000_create_groups.exs")
    end

    :ok
  end

  setup %{tmp_dir: directory} do
    # Real, independent connections are needed to exercise SQLite's write locks;
    # sandbox allowances would make all workers share a single transaction.
    options = [
      name: @repo_name,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5_000
    ]

    # Initialize the database before starting several connections, avoiding
    # contention while SQLite first configures its journal.
    start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    previous_repo = Repo.put_dynamic_repo(@repo_name)
    on_exit(fn -> Repo.put_dynamic_repo(previous_repo) end)
    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    %{repo_options: options}
  end

  test "committed groups and settlements survive a repository restart and migration rerun", %{
    repo_options: options
  } do
    Reservations.process_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_group(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 250})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()

    stop_supervised!(Repo)
    start_supervised!({Repo, options})
    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []

    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals
    assert totals == %{cash_held_cents: 250, cash_refunded_cents: 500, cash_retained_cents: 0}
  end

  test "only one competing update can apply against a revision" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 3
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional competing payments cannot overfund a deposit" do
    Reservations.process_batch([open_group()])

    results =
      race(fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 10_000
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 3
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "competing openings preserve group uniqueness" do
    results = race(fn index -> open_group(%{"operation_id" => "open-#{index}"}) end)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 3
    assert Reservations.get_group("group-81").revision == 1
  end

  defp race(build_operation) do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo_name)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.process_batch([build_operation.(index)]) |> hd()
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
