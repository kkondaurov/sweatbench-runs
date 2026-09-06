defmodule GroupStayWeb.Params do
  @moduledoc """
  Query parameter parsing shared by the read endpoints.
  """

  @doc """
  Parses the optional `on=YYYY-MM-DD` expiry reference date, defaulting to
  the current UTC date.
  """
  def parse_on(params, key \\ "on")

  def parse_on(params, key) do
    case params[key] do
      nil -> {:ok, Date.utc_today()}
      value -> parse_date(value)
    end
  end

  @doc """
  Parses a required ISO 8601 calendar date value.
  """
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  def parse_date(_value), do: :error
end
