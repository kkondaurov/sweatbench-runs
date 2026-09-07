defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Runs a transaction after acquiring SQLite's write lock.

  A competing writer can exhaust the connection's busy timeout. Only a failed
  BEGIN is retried: the callback has not run, so no operation can be replayed.
  Other storage errors propagate after Ecto rolls back the transaction.
  """
  def transact_immediate(fun), do: begin_immediate(fun, 3)

  defp begin_immediate(fun, retries_left) do
    transact(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message == "database is locked" and retries_left > 0 do
        Process.sleep(Enum.random(10..50))
        begin_immediate(fun, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
