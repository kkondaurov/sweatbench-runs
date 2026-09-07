defmodule GroupStayWeb.ExpiryDate do
  @moduledoc "Parses the optional expiry cutoff shared by finance and guest credit reads."

  def from_params(%{"on" => value}) when is_binary(value), do: Date.from_iso8601(value)
  def from_params(%{"on" => _}), do: {:error, :invalid_date}
  def from_params(_), do: {:ok, Date.utc_today()}
end
