defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case fetch_date(params) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          :not_available ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => %{"code" => "report_not_available"}})

          {:ok, report} ->
            json(conn, %{"data" => report})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
    end
  end

  defp fetch_date(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp fetch_date(_params), do: :error
end
