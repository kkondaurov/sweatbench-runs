defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  def show(conn, %{"date" => date}) do
    case GroupStay.Operations.parse_finance_report_date(date) do
      {:ok, date} -> render_report(conn, date)
      {:error, code} -> invalid_date(conn, code)
    end
  end

  def show(conn, _params), do: invalid_date(conn, "invalid_reporting_date")

  defp render_report(conn, date) do
    case GroupStay.Operations.daily_finance_report(date) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, code} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: code}})
    end
  end

  defp invalid_date(conn, code) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: code}})
  end
end
