defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def daily_report(conn, params) do
    case parse_date(Map.get(params, "date")) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          {:frozen, data} ->
            # A closed day is served from its stored report, byte for byte.
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, ~s({"data":#{data}}))

          {:error, "report_not_available"} ->
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
