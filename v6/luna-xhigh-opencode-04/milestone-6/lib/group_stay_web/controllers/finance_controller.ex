defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def daily_report(conn, %{"date" => date}) do
    case Operations.parse_required_report_date(date) do
      {:ok, date} -> render_report(conn, date)
      {:error, :invalid_date} -> invalid_date(conn)
    end
  end

  def daily_report(conn, _params), do: invalid_date(conn)

  defp render_report(conn, date) do
    case Operations.daily_finance_report(date) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, :not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
