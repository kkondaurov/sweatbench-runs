defmodule GroupStay.PersistenceCase do
  @moduledoc """
  Exercises real SQLite commits, independent connections, and repository restarts.

  Each test gets a database under the repository's tmp directory, copied from a
  migrated and checkpointed template. No SQL sandbox surrounds these operations.
  """
  use ExUnit.CaseTemplate

  alias GroupStay.Repo

  using do
    quote do
      import GroupStay.PersistenceCase, only: [race: 2]

      @moduletag :tmp_dir
      @moduletag capture_log: true
    end
  end

  setup_all do
    directory =
      Path.expand("../../tmp/persistence-template-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    template = Path.join(directory, "group_stay.db")

    {:ok, repo} =
      Repo.start_link(
        name: nil,
        database: template,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    after
      Supervisor.stop(repo)
      Repo.put_dynamic_repo(previous)
    end

    %{template: template}
  end

  # These tests use real commits and independent connections, outside the SQL
  # sandbox, to exercise SQLite locking and persistence across repository restarts.
  setup %{tmp_dir: directory, template: template} do
    database = Path.join(directory, "group_stay.db")
    # The migrated template was checkpointed before its connection was closed.
    File.cp!(template, database)

    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 100
    ]

    repo = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)

    %{repo: repo, options: options, database: database}
  end

  def race(repo, fun) do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> fun.(index)
          end
        end)
      end

    for %{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
