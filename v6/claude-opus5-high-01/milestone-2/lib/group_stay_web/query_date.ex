defmodule GroupStayWeb.QueryDate do
  @moduledoc """
  Reads the optional `on` query parameter shared by the finance reads.

  Without it the reads report expiry as of the current UTC date.
  """

  @doc "Returns the date the read should evaluate expiry against."
  def as_of(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def as_of(%{"on" => _value}), do: :error
  def as_of(_params), do: {:ok, Date.utc_today()}
end
