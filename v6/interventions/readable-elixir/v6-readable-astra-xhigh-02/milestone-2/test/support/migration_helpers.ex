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
end
