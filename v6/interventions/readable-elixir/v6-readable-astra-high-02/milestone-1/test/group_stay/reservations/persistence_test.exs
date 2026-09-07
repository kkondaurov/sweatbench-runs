defmodule GroupStay.Reservations.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}

  @moduletag :tmp_dir

  setup_all do
    migrations =
      Repo.config()[:priv]
      |> then(fn priv -> Path.join(priv || "priv/repo", "migrations/*.exs") end)
      |> Path.wildcard()
      |> Enum.map(fn path ->
        {version, _name} = path |> Path.basename() |> Integer.parse()
        [{module, _binary}] = Code.require_file(path)
        {version, module}
      end)

    %{migrations: migrations}
  end

  setup %{tmp_dir: directory, migrations: migrations} do
    # A real pool and an isolated file exercise SQLite locking and durability outside
    # the SQL sandbox. ExUnit's temporary directory stays within this repository.
    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5000
    ]

    # Initialize WAL and migrate with one connection before starting concurrent writers.
    # Multiple connections racing to initialize an empty SQLite file can report SQLITE_BUSY.
    initializer = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(initializer)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    stop_supervised!(Repo)

    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    %{repository: repository, options: options}
  end

  test "concurrent expected revisions allow exactly one writer", %{repository: repository} do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 2
    assert group.deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional concurrent payments do not lose cash or revisions", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 9
    assert group.deposit_paid_cents == 800
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "concurrent opens reserve a group identifier only once", %{repository: repository} do
    results = concurrently(repository, &open_group(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Repo.aggregate(GroupStay.Reservations.Room, :count) == 2
  end

  test "migrations are repeatable and balances survive repository restart", %{
    options: options,
    migrations: migrations
  } do
    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group")
    ])

    before = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger() == ledger
    assert ledger == %{cash_held_cents: 0, cash_refunded_cents: 100, cash_retained_cents: 0}
  end

  defp concurrently(repository, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repository)
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          [result] = Reservations.submit_batch([build_operation.(index)])
          result
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end
end
