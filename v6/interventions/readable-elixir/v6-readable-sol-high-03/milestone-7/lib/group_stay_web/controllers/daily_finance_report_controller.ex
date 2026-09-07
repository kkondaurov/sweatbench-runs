defmodule GroupStayWeb.DailyFinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"date" => value}) do
    with {:ok, date} <- parse_date(value),
         {:ok, report} <- Reservations.daily_finance_report(date) do
      json(conn, %{data: report})
    else
      {:error, :invalid_reporting_date} ->
        invalid_date(conn)

      {:error, :report_not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "report_not_available"}})
    end
  end

  def show(conn, _params), do: invalid_date(conn)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_reporting_date}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
