defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        case Reservations.daily_finance_report(date) do
          {:ok, report} ->
            json(conn, %{"data" => report})

          :report_not_available ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => %{"code" => "report_not_available"}})
        end

      _ ->
        invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
