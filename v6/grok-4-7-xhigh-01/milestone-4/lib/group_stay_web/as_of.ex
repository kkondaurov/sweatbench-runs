defmodule GroupStayWeb.AsOf do
  @moduledoc false

  def parse(params) when is_map(params) do
    case Map.get(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
