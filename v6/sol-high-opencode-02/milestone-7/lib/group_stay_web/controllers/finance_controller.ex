defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def daily_report(conn, params) do
    with {:ok, date} <- reporting_date(params["date"]),
         {:ok, report} <- Bookings.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      :invalid_date ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})

      :not_available ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  defp reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :invalid_date
    end
  end

  defp reporting_date(_value), do: :invalid_date
end
