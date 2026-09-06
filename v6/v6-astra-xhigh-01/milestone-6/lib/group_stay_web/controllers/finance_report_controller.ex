defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller
  alias GroupStay.FinanceReporting

  def show(conn, params) do
    with {:ok, date} <- FinanceReporting.parse_date(params["date"]),
         {:ok, report} <- FinanceReporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
