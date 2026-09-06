defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, params) do
    json(conn, %{"data" => Ledger.totals(as_of_date(params["on"]))})
  end

  defp as_of_date(nil), do: Date.utc_today()

  defp as_of_date(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end
end
