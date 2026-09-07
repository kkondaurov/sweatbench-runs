defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    with {:ok, date} <- Finance.reporting_date(params["date"]),
         {:ok, report} <- Finance.daily_report(date) do
      render(conn, :show, report: report)
    else
      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
