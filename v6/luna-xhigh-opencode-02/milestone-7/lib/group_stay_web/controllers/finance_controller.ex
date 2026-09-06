defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def daily_report(conn, %{"date" => date}) do
    case Date.from_iso8601(date) do
      {:ok, date} -> render_report(conn, date)
      {:error, _reason} -> invalid_reporting_date(conn)
    end
  end

  def daily_report(conn, _params), do: invalid_reporting_date(conn)

  defp render_report(conn, date) do
    case Finance.daily_report(date) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
