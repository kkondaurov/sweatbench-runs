defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def daily_report(conn, params) do
    with {:ok, date} <- OperationalCore.finance_report_date(params["date"]),
         {:ok, report} <- OperationalCore.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      :not_available ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end
end
