defmodule GroupStay.Repo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    # Keep native lock waits short so waiting writers cannot monopolize the
    # dirty schedulers needed by the current writer to finish its transaction.
    {:ok, Keyword.put_new(config, :busy_timeout, 50)}
  end

  @doc """
  Acquires the SQLite writer lock before running an operation. Only lock failures
  at BEGIN are retried: the callback has not run, so no effects can be duplicated.
  Other database failures propagate to the caller.
  """
  def write_transaction(fun), do: begin_write(fun, 20)

  defp begin_write(fun, attempts) do
    transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if attempts > 0 and error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep(10 + :rand.uniform(40))
        begin_write(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
