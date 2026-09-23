defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReports

  def show(conn, params) do
    with {:ok, date} <- report_date(params),
         {:ok, report} <- FinanceReports.daily_report(date) do
      json(conn, %{data: report})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp report_date(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp report_date(_params), do: :error
end
