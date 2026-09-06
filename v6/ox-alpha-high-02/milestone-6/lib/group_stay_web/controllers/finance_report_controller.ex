defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, %{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          :error ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})
        end

      {:error, _} ->
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
