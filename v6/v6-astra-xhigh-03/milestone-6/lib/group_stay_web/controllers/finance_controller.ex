defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  def daily_report(conn, params) do
    with {:ok, date} <- parse(params["date"]),
         {:ok, report} <- GroupStay.FinanceReporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, "report_not_available"} ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "report_not_available"}})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end

  defp parse(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse(_value), do: :error
end
