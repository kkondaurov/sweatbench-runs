defmodule GroupStayWeb.AsOf do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter into the date that
  read endpoints report expiry as of. Without the parameter the current UTC
  date is used.
  """

  def parse(params) do
    case Map.get(params, "on") do
      nil -> {:ok, Date.utc_today()}
      value when is_binary(value) -> parse_date(value)
      _ -> :error
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end
end
