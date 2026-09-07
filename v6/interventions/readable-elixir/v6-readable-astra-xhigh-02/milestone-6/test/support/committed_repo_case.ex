defmodule GroupStay.CommittedRepoCase do
  @moduledoc """
  An isolated on-disk repository with real commits and separate connections.
  Use for concurrency, rollback and restart tests that a SQL sandbox would hide.
  """

  use ExUnit.CaseTemplate

  alias GroupStay.Repo
  import GroupStay.MigrationHelpers

  using do
    quote do
      @repo_name Module.concat(__MODULE__, Repo)
      import GroupStay.CommittedRepoCase
    end
  end

  setup_all %{module: module} do
    repo_name = Module.concat(module, Repo)
    directory = Path.expand("tmp/committed-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      if pid = Process.whereis(repo_name), do: Supervisor.stop(pid)
      remove_database(directory)
    end)

    options = [
      name: repo_name,
      database: Path.join(directory, "group_stay.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      # These tests deliberately burst more writers than there are connections.
      # Allow queued callers to wait through SQLite's busy BEGIN timeout instead
      # of DBConnection dropping them before their transaction can start.
      queue_target: 5_000
    ]

    # Establish WAL with one connection before opening the pool to avoid a race
    # between connections setting the initial journal mode.
    start_repo(Keyword.put(options, :pool_size, 1))
    Repo.put_dynamic_repo(repo_name)
    Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false)
    Supervisor.stop(Process.whereis(repo_name))
    start_repo(options)

    %{repo_name: repo_name, repo_options: options}
  end

  setup %{repo_name: repo_name} do
    Repo.put_dynamic_repo(repo_name)

    for schema <- [
          GroupStay.Finance.Entry,
          GroupStay.Finance.ReportingPeriod,
          GroupStay.Accounting.Allocation,
          GroupStay.HotelCredit.Entitlement,
          GroupStay.Accounting.CashSettlement,
          GroupStay.Accounting.CashPayment,
          GroupStay.Operations.Operation,
          GroupStay.HotelCredit.Application,
          GroupStay.HotelCredit.Lot,
          GroupStay.Reservations.Room,
          GroupStay.Reservations.Group
        ] do
      Repo.delete_all(schema)
    end

    :ok
  end

  def start_repo(options) do
    {:ok, pid} = Repo.start_link(options)
    Process.unlink(pid)
    pid
  end

  def concurrently(operations, repo_name) do
    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo_name)

          receive do
            :apply -> GroupStay.Operations.process(operation)
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :apply))
    Task.await_many(tasks, 15_000)
  end
end
