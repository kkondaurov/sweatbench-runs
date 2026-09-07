defmodule GroupStay.ReservationsPersistenceTest do
  # These tests use an isolated on-disk database and real transactions, because
  # sandbox ownership would serialize or wrap the transactions being exercised.
  use ExUnit.Case, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}

  @migration GroupStay.Repo.Migrations.CreateGroups
  @migrations [{20_260_907_000_000, @migration}]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Repo
      |> Ecto.Migrator.migrations_path()
      |> Path.join("20260907000000_create_groups.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    directory =
      Path.expand("../../tmp/reservations-#{Ecto.UUID.generate()}", __DIR__)

    File.mkdir_p!(directory)
    database = Path.join(directory, "reservations.db")
    on_exit(fn -> remove_database(directory) end)

    start_repo(database, 1)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_000
           ]

    stop_supervised!(Repo)
    repo = start_repo(database, 4)

    {:ok, database: database, repo: repo}
  end

  test "migrated records and finance settlements survive repository restart", %{
    database: database
  } do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_operation(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 123})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()
    stop_supervised!(Repo)
    start_repo(database, 1)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals
    assert totals == %{cash_held_cents: 123, cash_refunded_cents: 500, cash_retained_cents: 0}
  end

  test "competing conditional payments apply exactly once", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "competing unconditional payments do not lose cash or revision increments", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert Reservations.get_group("group-81").revision == 9
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "competing openings preserve group uniqueness", %{repo: repo} do
    results = concurrently(repo, &open_operation(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group-81").revision == 1
  end

  @tag :capture_log
  test "a writer outlasting the busy timeout does not lose or duplicate a payment", %{repo: repo} do
    Reservations.process_batch([open_operation()])
    parent = self()

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(
          fn ->
            send(parent, :write_lock_acquired)
            Process.sleep(2_200)
          end,
          mode: :immediate
        )
      end)

    assert_receive :write_lock_acquired, 1_000

    assert [%{status: "applied", revision: 2}] =
             Reservations.process_batch([
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
             ])

    assert {:ok, :ok} = Task.await(writer)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  defp start_repo(database, pool_size) do
    repo =
      start_supervised!(
        {Repo,
         name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: pool_size}
      )

    Repo.put_dynamic_repo(repo)
    repo
  end

  defp remove_database(directory) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, _, reason} when reason in [:eexist, :enotempty] ->
        # Native SQLite cleanup can briefly change WAL files during teardown.
        File.rm_rf!(directory)

      {:error, path, reason} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrently(repo, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              [result] = Reservations.process_batch([build_operation.(index)])
              result
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
