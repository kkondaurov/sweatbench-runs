defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def daily_report(conn, params) do
    with {:ok, date} <- fetch_date(params),
         {:ok, report} <- Finance.daily_report(date) do
      render(conn, :daily_report, report: report)
    else
      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> render(:error, code: "report_not_available")

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, code: "invalid_reporting_date")
    end
  end

  defp fetch_date(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp fetch_date(_params), do: :error
end
