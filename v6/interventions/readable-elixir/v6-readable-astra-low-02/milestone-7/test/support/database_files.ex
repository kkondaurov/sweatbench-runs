defmodule GroupStay.DatabaseFiles do
  @moduledoc false

  # SQLite's native cleanup can finish after its pool terminates. Allow a short,
  # bounded retry for concurrent removal of WAL/SHM files in disposable databases.
  def remove!(directory, attempts \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty, :enoent] and attempts > 0 ->
        Process.sleep(10)
        remove!(directory, attempts - 1)

      {:error, reason, file} ->
        raise File.Error, reason: reason, action: "remove temporary database", path: file
    end
  end
end
