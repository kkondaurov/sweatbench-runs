defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Acquires SQLite's write lock before reading data used by an operation.

  A competing writer can outlast the connection's busy timeout. Retry only a
  failed BEGIN, which guarantees that the operation body has not run. Errors
  during the body or commit are never retried.
  """
  def with_write_transaction(fun), do: begin_write_transaction(fun, 3)

  defp begin_write_transaction(fun, retries) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if retries > 0 and error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep(10 * (4 - retries))
        begin_write_transaction(fun, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
