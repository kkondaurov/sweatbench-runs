defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.GroupReservations

  def show(conn, params) do
    with {:ok, date} <- report_date(params),
         {:ok, report} <- GroupReservations.daily_finance_report_response(date) do
      render_report(conn, report)
    else
      :invalid_reporting_date ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp report_date(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :invalid_reporting_date
    end
  end

  defp report_date(_params), do: :invalid_reporting_date

  defp render_report(conn, {:snapshot, data_json}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"data":#{data_json}}))
  end

  defp render_report(conn, {:current, report}) do
    json(conn, %{data: report})
  end
end
