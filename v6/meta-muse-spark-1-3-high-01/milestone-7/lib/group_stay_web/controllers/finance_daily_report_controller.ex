defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Batches.daily_report(Map.get(params, "date")) do
      {:ok, report, status} ->
        json(conn, %{data: Map.put(report, "status", status)})

      {:error, "invalid_reporting_date"} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, "report_not_available"} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
