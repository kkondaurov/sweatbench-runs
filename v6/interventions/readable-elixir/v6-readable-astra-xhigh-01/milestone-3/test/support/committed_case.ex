defmodule GroupStay.CommittedCase do
  @moduledoc """
  An isolated, migrated SQLite file with independent connections and real commits.

  Use for locking, rollback, and restart tests that a shared sandbox transaction
  cannot exercise. Each test gets a copy of a migrated template inside `tmp/`.
  """

  use ExUnit.CaseTemplate

  alias GroupStay.Repo

  setup_all do
    directory = Path.expand("tmp/committed-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    template = Path.join(directory, "template.db")

    repo =
      start_supervised!(
        {Repo, name: nil, database: template, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    after
      Repo.put_dynamic_repo(previous_repo)
      stop_supervised!(Repo)
    end

    %{directory: directory, template: template}
  end

  setup %{directory: directory, template: template} do
    database = Path.join(directory, "#{System.unique_integer([:positive, :monotonic])}.db")
    File.cp!(template, database)

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 4}
      )

    Repo.put_dynamic_repo(repo)
    %{repo: repo, database: database}
  end
end
