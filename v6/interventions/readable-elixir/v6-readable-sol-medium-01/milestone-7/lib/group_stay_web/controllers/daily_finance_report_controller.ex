defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting

  def show(conn, %{"date" => value}) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, report} <- FinanceReporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, :report_not_available} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})

      _invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
