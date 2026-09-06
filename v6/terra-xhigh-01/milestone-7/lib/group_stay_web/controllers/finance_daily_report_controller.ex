defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"date" => date}) when is_binary(date) do
    with {:ok, date} <- Date.from_iso8601(date) do
      case Reservations.daily_finance_report(date) do
        {:ok, report} -> json(conn, %{data: report})
        :report_not_available -> report_not_available(conn)
      end
    else
      _ -> invalid_reporting_date(conn)
    end
  end

  def show(conn, _params), do: invalid_reporting_date(conn)

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
