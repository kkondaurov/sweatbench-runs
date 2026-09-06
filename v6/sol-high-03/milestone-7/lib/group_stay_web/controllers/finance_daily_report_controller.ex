defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting

  def show(conn, %{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> render_report(conn, FinanceReporting.daily_report(date))
      {:error, _reason} -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, {:ok, report}), do: json(conn, %{data: report})

  defp render_report(conn, {:error, :not_available}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
