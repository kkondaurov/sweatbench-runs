defmodule GroupStayWeb.AsOf do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter used by read endpoints
  to report expiry as of a date, defaulting to the current UTC date.
  """

  @doc """
  Returns `{:ok, date}` for a missing or valid `on` parameter, or `:error`
  for an unusable one.
  """
  def fetch(params) do
    case Map.get(params, "on") do
      nil -> {:ok, Date.utc_today()}
      value when is_binary(value) -> parse(value)
      _value -> :error
    end
  end

  defp parse(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end
end
