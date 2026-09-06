defmodule GroupStayWeb.FinanceReportsController do
  use GroupStayWeb, :controller

  def daily(conn, %{"date" => date}) do
    case GroupStay.daily_finance_report(date) do
      {:ok, report} ->
        json(conn, %{"data" => report})

      {:error, :invalid_reporting_date} ->
        invalid_reporting_date(conn)

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})
    end
  end

  def daily(conn, _params), do: invalid_reporting_date(conn)

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
