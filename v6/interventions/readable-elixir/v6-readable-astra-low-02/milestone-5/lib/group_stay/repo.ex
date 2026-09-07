defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Runs an atomic SQLite write, retrying contention before the transaction begins.

  Only a failed BEGIN is safe to retry here: once the callback has started, errors
  propagate normally so an operation can never be accidentally applied twice.
  """
  def write_transaction(fun), do: begin_write(fun, 5)

  defp begin_write(fun, retries) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if error.message == "database is locked" &&
           error.statement == "BEGIN IMMEDIATE TRANSACTION" && retries > 0 do
        Process.sleep(10 * (6 - retries))
        begin_write(fun, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
