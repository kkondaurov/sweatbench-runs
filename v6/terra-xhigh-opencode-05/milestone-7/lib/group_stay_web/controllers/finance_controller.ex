defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def daily_report(conn, %{"date" => date}) when is_binary(date) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, report} <- Reservations.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      :not_available -> report_not_available(conn)
      _ -> invalid_reporting_date(conn)
    end
  end

  def daily_report(conn, _params), do: invalid_reporting_date(conn)

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end

  defp report_not_available(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end
end
