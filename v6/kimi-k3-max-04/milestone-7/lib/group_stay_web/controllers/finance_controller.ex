defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, params) do
    case Map.get(params, "date") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> serve(conn, date)
          {:error, _} -> invalid_date(conn)
        end

      _other ->
        invalid_date(conn)
    end
  end

  defp serve(conn, date) do
    case Finance.daily_report(date) do
      :not_available ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})

      report ->
        json(conn, %{data: report})
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
