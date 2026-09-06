defmodule GroupStayWeb.FinanceController do
  @moduledoc """
  Reads the daily finance report for one date: the opening position of every
  property's held cash and the company-wide hotel-credit liability, the
  movements of the day, and the closing position.
  """

  use GroupStayWeb, :controller

  def daily_report(conn, params) do
    with {:ok, date} <- parse_date(params["date"]),
         {:ok, report} <- GroupStay.Finance.daily_report(date) do
      json(conn, %{"data" => report})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})
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
