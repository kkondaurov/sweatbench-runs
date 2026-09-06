defmodule GroupStayWeb.FinanceDailyReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance.Report

  def show(conn, params) do
    with {:ok, date} <- fetch_date(params),
         {:ok, report} <- Report.daily_report(date) do
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

  defp fetch_date(params) do
    case Map.fetch(params, "date") do
      {:ok, value} when is_binary(value) -> parse_date(value)
      _ -> {:error, :invalid_reporting_date}
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end
end
