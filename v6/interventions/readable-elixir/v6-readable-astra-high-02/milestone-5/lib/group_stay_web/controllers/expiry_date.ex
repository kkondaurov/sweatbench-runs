defmodule GroupStayWeb.ExpiryDate do
  @moduledoc "Parses the optional expiry date shared by finance and guest credit reads."

  def parse(%{"on" => on}), do: GroupStay.Reservations.Operation.date(on)
  def parse(_params), do: {:ok, Date.utc_today()}
end
