defmodule GroupStayWeb.OnParam do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter shared by the finance
  read endpoints. Without it, expiry is reported as of the current UTC date.
  """

  @doc """
  Returns `{:ok, date}` for a missing or well-formed `on` parameter and
  `:error` for a malformed one.
  """
  def parse(params) when is_map(params) do
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
