defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance.Report

  def daily_report(conn, params) do
    with {:ok, date} <- report_date(params),
         {:ok, report} <- Report.for_date(date) do
      render(conn, :daily_report, report: report)
    else
      {:error, :invalid_reporting_date} ->
        error(conn, :unprocessable_entity, "invalid_reporting_date")

      # Nothing is reportable before the inception point finance chose.
      {:error, :report_not_available} ->
        error(conn, :not_found, "report_not_available")
    end
  end

  defp report_date(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp report_date(_params), do: {:error, :invalid_reporting_date}

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
