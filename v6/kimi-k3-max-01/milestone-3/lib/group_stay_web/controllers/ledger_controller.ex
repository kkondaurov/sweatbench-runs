defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, params) do
    json(conn, %{data: Ledger.totals(as_of(params))})
  end

  # Credit expiry is reported as of the optional `on` date, or the current
  # UTC date.
  defp as_of(params) do
    with value when is_binary(value) <- Map.get(params, "on"),
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _other -> Date.utc_today()
    end
  end
end
