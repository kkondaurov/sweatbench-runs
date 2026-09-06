defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReports

  def show(conn, %{"date" => date}) do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        case FinanceReports.get(date) do
          {:ok, report} -> json(conn, %{data: report})
          :not_available -> not_available(conn)
        end

      {:error, _reason} ->
        invalid_date(conn)
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end

  defp not_available(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end
end
