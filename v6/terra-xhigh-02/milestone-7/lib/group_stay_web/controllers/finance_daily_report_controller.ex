defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> render_report(conn, date)
      {:error, _reason} -> invalid_reporting_date(conn)
    end
  end

  def show(conn, _params), do: invalid_reporting_date(conn)

  defp render_report(conn, date) do
    case Groups.daily_finance_report(date) do
      {:ok, report} ->
        json(conn, %{"data" => report})

      :not_available ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})
    end
  end

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
