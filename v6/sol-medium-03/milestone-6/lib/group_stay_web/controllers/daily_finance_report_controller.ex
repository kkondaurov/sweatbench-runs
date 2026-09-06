defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"date" => date}) when is_binary(date) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, report} <- Reservations.daily_finance_report(date) do
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
