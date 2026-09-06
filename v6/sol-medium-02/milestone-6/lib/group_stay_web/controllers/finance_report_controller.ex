defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting

  def show(conn, %{"date" => value}) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, report} <- FinanceReporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})

      _ ->
        invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
