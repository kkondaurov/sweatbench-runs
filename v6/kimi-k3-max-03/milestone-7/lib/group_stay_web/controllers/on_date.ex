defmodule GroupStayWeb.OnDate do
  @moduledoc """
  Parses the optional `on=YYYY-MM-DD` query parameter. Expiry is reported as
  of that date when it is a valid ISO date; otherwise the current UTC date
  is used.
  """

  def from_params(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end

  def from_params(_params), do: Date.utc_today()
end
