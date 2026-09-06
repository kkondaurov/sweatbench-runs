defmodule GroupStayWeb.AsOfParam do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter used to report expiry
  as of a given date. Without it, the current UTC date is used.
  """

  def parse(params) do
    case Map.get(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :error
        end

      _other ->
        :error
    end
  end
end
