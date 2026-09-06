defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, %{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> render_report(conn, Finance.daily_report(date))
      _ -> invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp render_report(conn, :not_available) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end

  defp render_report(conn, report), do: json(conn, %{data: report})

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
