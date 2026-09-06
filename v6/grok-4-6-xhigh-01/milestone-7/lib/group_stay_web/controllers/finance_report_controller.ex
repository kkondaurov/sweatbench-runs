defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case parse_date(params["date"]) do
      {:ok, date} ->
        case Groups.daily_finance_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          :not_available ->
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

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_), do: :error
end
