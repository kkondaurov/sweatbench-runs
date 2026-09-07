defmodule GroupStay.DatabaseFiles do
  @moduledoc false

  # SQLite's native resource cleanup may briefly outlive the repository process
  # and touch its WAL files. Retry directory removal while those handles close.
  def remove_directory!(directory, attempts \\ 20) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, _reason, _file} when attempts > 1 ->
        Process.sleep(25)
        remove_directory!(directory, attempts - 1)

      {:error, reason, file} ->
        raise File.Error, reason: reason, action: "remove database files", path: file
    end
  end
end
