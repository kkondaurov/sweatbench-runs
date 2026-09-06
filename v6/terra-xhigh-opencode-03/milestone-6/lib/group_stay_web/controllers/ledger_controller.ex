defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params), do: json(conn, %{data: Reservations.ledger(report_date(params))})

  defp report_date(%{"on" => value}) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> Date.utc_today()
    end
  end

  defp report_date(_params), do: Date.utc_today()
end
