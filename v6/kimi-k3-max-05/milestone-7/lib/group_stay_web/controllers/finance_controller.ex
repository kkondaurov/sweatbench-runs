defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case parse_date(params["date"]) do
      {:ok, date} ->
        case Finance.daily_report(date) do
          nil ->
            conn
            |> put_status(404)
            |> json(%{"error" => %{"code" => "report_not_available"}})

          report ->
            json(conn, %{"data" => report})
        end

      :error ->
        conn
        |> put_status(422)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error
end
