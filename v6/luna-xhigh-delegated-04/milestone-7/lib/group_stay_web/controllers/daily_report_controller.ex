defmodule GroupStayWeb.DailyReportController do
  use GroupStayWeb, :controller

  def show(conn, %{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> render_report(conn, date)
      {:error, _reason} -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, date) do
    case GroupStay.daily_finance_report(date) do
      {:ok, report} ->
        json(conn, %{"data" => report})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
