defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def daily_report(conn, %{"date" => date}) do
    with {:ok, date} <- Groups.parse_reporting_date(date),
         {:ok, report} <- Groups.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      :error -> unavailable_date(conn)
      {:error, "report_not_available"} -> report_not_available(conn)
    end
  end

  def daily_report(conn, _params), do: unavailable_date(conn)

  defp unavailable_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end

  defp report_not_available(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end
end
