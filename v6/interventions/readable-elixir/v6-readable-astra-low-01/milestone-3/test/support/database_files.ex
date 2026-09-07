defmodule GroupStay.DatabaseFiles do
  @moduledoc false

  # SQLite's native handles can finish removing WAL sidecars just after the repo
  # stops. Retry only directory-removal races, and still fail on persistent errors.
  def remove!(directory, attempts \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty, :enoent] and attempts > 1 ->
        Process.sleep(10)
        remove!(directory, attempts - 1)

      {:error, _, _} ->
        File.rm_rf!(directory)
    end
  end
end
