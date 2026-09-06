defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  # The daily finance report explains how held cash and hotel-credit
  # liability moved on one day. A missing or invalid date is
  # invalid_reporting_date; a date before reporting started, or before
  # starts_on, has no report.
  def daily_report(conn, params) do
    with {:ok, date} <- resolve_date(params["date"]),
         {:ok, report} <- GroupStay.Finance.daily_report(date) do
      json(conn, %{"data" => report})
    else
      {:error, :invalid_reporting_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})
    end
  end

  defp resolve_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp resolve_date(_value), do: {:error, :invalid_reporting_date}
end
