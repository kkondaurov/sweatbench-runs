defmodule GroupStay.MigrationHelpers do
  @moduledoc false

  # Reuse migration modules across isolated test databases instead of repeatedly
  # compiling the same modules through Ecto.Migrator's directory loader.
  def migrations do
    Path.wildcard("priv/repo/migrations/*.exs")
    |> Enum.map(fn path ->
      {version, "_" <> name} = Integer.parse(Path.basename(path, ".exs"))
      module = Module.concat(GroupStay.Repo.Migrations, Macro.camelize(name))
      unless Code.ensure_loaded?(module), do: Code.require_file(path)
      {version, module}
    end)
  end

  # SQLite may remove WAL sidecars just after its connection processes exit.
  def remove_database(directory, attempts \\ 10) do
    case File.rm_rf(directory) do
      {:ok, _files} ->
        :ok

      {:error, :eexist, _path} when attempts > 0 ->
        Process.sleep(10)
        remove_database(directory, attempts - 1)

      {:error, _reason, _path} ->
        File.rm_rf!(directory)
    end
  end
end
