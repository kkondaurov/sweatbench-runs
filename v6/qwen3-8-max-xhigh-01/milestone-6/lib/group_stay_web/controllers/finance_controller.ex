defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def daily_report(conn, params) do
    with {:ok, date} <- fetch_date(params),
         {:ok, report} <- Finance.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp fetch_date(params) do
    case Map.get(params, "date") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, :invalid_reporting_date}
        end

      _value ->
        {:error, :invalid_reporting_date}
    end
  end
end
