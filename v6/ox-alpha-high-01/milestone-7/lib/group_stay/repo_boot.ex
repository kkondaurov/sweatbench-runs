defmodule GroupStay.RepoBoot do
  @moduledoc """
  Prepares the repository before boot-time migrations run.

  In the test environment the repository uses the SQL sandbox. When the service
  runs on its own (`mix phx.server`), the sandbox switches to `:auto` so boot
  migrations can check connections out. Under `mix test`, the test helper
  switches the sandbox back to `:manual` once the application has started.
  """

  use Task, restart: :transient

  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  def run do
    if GroupStay.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.mode(GroupStay.Repo, :auto)
    end

    :ok
  end
end
