defmodule GroupStayWeb.DateParam do
  @moduledoc """
  Parses the optional `on` query parameter used by read endpoints to report
  date-dependent state. Without it, the current UTC date is used.
  """

  def parse(nil), do: {:ok, Date.utc_today()}

  def parse(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  def parse(_other), do: :error
end
