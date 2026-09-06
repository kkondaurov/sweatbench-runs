defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  def daily_report(conn, params) do
    with {:ok, date} <- parse_date(params["date"]),
         {:ok, report} <- GroupStay.Finance.daily_report(date) do
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

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_reporting_date}
    end
  end

  defp parse_date(_other), do: {:error, :invalid_reporting_date}
end
