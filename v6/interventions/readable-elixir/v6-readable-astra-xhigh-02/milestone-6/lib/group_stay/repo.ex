defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Acquires SQLite's write lock before looking up or applying a partner operation.

  A busy BEGIN has not run the callback and is safe to retry. Never retry errors
  from statements or commit: those may have different causes or uncertain results.
  Bound retries so an unavailable database still surfaces as an infrastructure error.
  """
  def write_transaction(fun), do: begin_write(fun, 3)

  defp begin_write(fun, retries_left) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if retries_left > 0 and error.statement == "BEGIN IMMEDIATE TRANSACTION" and
           error.message in ["database is locked", "Database is busy"] do
        Process.sleep(25)
        begin_write(fun, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
