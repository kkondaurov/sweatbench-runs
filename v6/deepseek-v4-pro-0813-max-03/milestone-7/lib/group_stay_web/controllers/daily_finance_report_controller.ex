defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case parse_date(params) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          _not_available ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  defp parse_date(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_params), do: :error
end
