defmodule GroupStay.TestFiles do
  @moduledoc false

  def remove_directory!(directory, attempts \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and attempts > 1 ->
        # Directory removal can race with SQLite's final WAL cleanup on shutdown.
        Process.sleep(10)
        remove_directory!(directory, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test directory", path: path
    end
  end
end
