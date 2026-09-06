defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def daily_report(conn, params) do
    case Operations.daily_finance_report(params["date"]) do
      {:ok, report} -> json(conn, %{data: report})
      {:error, :invalid_reporting_date} -> invalid_reporting_date(conn)
      {:error, :report_not_available} -> report_not_available(conn)
    end
  end

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
