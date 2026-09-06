defmodule GroupStayWeb.DateParam do
  @moduledoc """
  Parses the optional `on` ISO 8601 date query parameter used by read
  endpoints. When absent, expiry is reported as of the current UTC date.
  """

  def reference_date(nil), do: {:ok, Date.utc_today()}

  def reference_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def reference_date(_value), do: :error
end
