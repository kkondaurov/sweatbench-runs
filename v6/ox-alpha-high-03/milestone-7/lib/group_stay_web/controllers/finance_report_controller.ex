defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance.Reporting

  def show(conn, params) do
    case Reporting.parse_date(params["date"]) do
      {:ok, date} ->
        case Reporting.daily_report(date) do
          {:ok, report} ->
            json(conn, %{"data" => report})

          :not_available ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => %{"code" => "report_not_available"}})
        end

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
    end
  end
end
