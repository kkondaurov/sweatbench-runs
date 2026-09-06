defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    with {:ok, date} <- reporting_date(params["date"]),
         {:ok, report} <- Operations.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :not_available} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp reporting_date(_), do: :error
end
