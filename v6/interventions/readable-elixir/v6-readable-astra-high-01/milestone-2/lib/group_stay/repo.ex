defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Runs a write transaction, acquiring SQLite's write lock before reading state.

  A competing writer can outlast SQLite's busy timeout. Retry only a failed
  BEGIN, when the callback has not run; errors during the callback or commit
  must propagate because replaying them could duplicate an accounting operation.
  """
  def write_transaction(fun), do: write_transaction(fun, 3)

  defp write_transaction(fun, retries_left) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if retries_left > 0 and error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message in ["database is locked", "Database is busy"] do
        Process.sleep(25 * (4 - retries_left))
        write_transaction(fun, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
