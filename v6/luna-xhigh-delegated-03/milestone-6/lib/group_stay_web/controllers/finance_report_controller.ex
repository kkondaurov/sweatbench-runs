defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.daily_finance_report(params) do
      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})

      report ->
        json(conn, %{data: report})
    end
  end
end
