defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Acquires SQLite's write lock before reading balances or revisions.

  Contending writers can exhaust SQLite's busy timeout, particularly during startup.
  Retry only a failed BEGIN: the operation has not run yet, so no accounting change
  can be duplicated. Errors during the operation or commit are never retried here.
  """
  def with_write_lock(fun), do: begin_transaction(fun, 3)

  defp begin_transaction(fun, retries_left) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message == "database is locked" and retries_left > 0 do
        Process.sleep(10 * (4 - retries_left))
        begin_transaction(fun, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
