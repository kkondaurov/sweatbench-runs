defmodule GroupStay.TestDatabase do
  @moduledoc false

  def migrations do
    for path <- Path.wildcard("priv/repo/migrations/*.exs") |> Enum.sort() do
      [version, name] = path |> Path.basename(".exs") |> String.split("_", parts: 2)
      module = Module.concat(GroupStay.Repo.Migrations, Macro.camelize(name))
      unless Code.ensure_loaded?(module), do: Code.require_file(path)
      {String.to_integer(version), module}
    end
  end

  def remove!(directory), do: remove!(directory, 20)

  # Mounted filesystems can briefly report a nonempty directory after SQLite's
  # files have been deleted. Retry only that cleanup condition, with a bound.
  defp remove!(directory, attempts) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and attempts > 0 ->
        Process.sleep(10)
        remove!(directory, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove", path: path
    end
  end
end
