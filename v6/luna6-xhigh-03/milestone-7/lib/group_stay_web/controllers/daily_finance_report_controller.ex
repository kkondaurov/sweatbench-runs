defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"date" => value}) do
    case parse_date(value) do
      {:ok, date} ->
        case Groups.daily_finance_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          {:error, :report_not_available} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})
        end

      :error ->
        invalid_reporting_date(conn)
    end
  end

  def show(conn, _params), do: invalid_reporting_date(conn)

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error
end
