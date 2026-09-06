defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    with {:ok, date} <- Groups.daily_reporting_date(params),
         {:ok, report} <- Groups.daily_finance_report(date) do
      json(conn, %{"data" => report})
    else
      :error -> invalid_reporting_date(conn)
      :not_available -> report_not_available(conn)
    end
  end

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end

  defp report_not_available(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => %{"code" => "report_not_available"}})
  end
end
