defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case parse_date(params["date"]) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, report} ->
            json(conn, %{"data" => report})

          {:error, :not_started} ->
            not_available(conn)

          {:error, :before_start} ->
            not_available(conn)
        end

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => code}})
    end
  end

  defp parse_date(nil), do: {:error, "invalid_reporting_date"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_reporting_date"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_reporting_date"}

  defp not_available(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => %{"code" => "report_not_available"}})
  end
end
