defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case parse_date(Map.get(params, "date")) do
      {:ok, date} ->
        case GroupStay.Groups.daily_finance_report(date) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})

          report ->
            json(conn, %{data: report})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error
end
