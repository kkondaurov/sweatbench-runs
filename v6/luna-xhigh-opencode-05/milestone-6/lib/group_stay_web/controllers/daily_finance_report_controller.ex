defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> render_report(conn, Groups.daily_finance_report(date))
      {:error, _reason} -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, {:ok, report}), do: json(conn, %{"data" => report})

  defp render_report(conn, {:error, :report_not_available}) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => %{"code" => "report_not_available"}})
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
