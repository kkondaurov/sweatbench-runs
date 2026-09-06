defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Operations.daily_finance_report(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :not_available} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
