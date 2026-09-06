defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting
  alias GroupStay.Operations

  def show(conn, %{"date" => date}) do
    case Operations.parse_as_of(date) do
      {:ok, report_date} ->
        case FinanceReporting.daily_report(report_date) do
          {:ok, report} ->
            json(conn, %{data: report})

          {:error, %{code: code}} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: code}})
        end

      {:error, _code} ->
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
