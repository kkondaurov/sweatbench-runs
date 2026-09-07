defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    with {:ok, date} <- reporting_date(params),
         {:ok, report} <- Finance.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp reporting_date(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp reporting_date(_params), do: {:error, :invalid_reporting_date}
end
