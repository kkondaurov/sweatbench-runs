defmodule GroupStayWeb.OnDate do
  @moduledoc """
  Parses the optional `on` query parameter used by read endpoints to report
  date-dependent state. Without it, the current UTC date is used.
  """

  @doc """
  Returns `{:ok, date}` for a missing or valid `on` parameter, or `:error`
  when the parameter cannot be parsed as an ISO 8601 date.
  """
  def fetch(params) do
    case Map.fetch(params, "on") do
      :error -> {:ok, Date.utc_today()}
      {:ok, value} when is_binary(value) -> parse(value)
      _ -> :error
    end
  end

  defp parse(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end
end
