defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case Reservations.get_daily_finance_report(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
