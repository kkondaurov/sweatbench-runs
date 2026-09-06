defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"date" => date}) do
    case Date.from_iso8601(date) do
      {:ok, report_date} -> render_report(conn, report_date)
      {:error, _reason} -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, report_date) do
    case Operations.get_daily_report(report_date) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, "report_not_available"} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
