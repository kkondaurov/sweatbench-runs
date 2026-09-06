defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def daily_report(conn, %{"date" => value}) do
    case Date.from_iso8601(value) do
      {:ok, date} -> respond(conn, Reservations.daily_finance_report(date))
      {:error, _} -> invalid_reporting_date(conn)
    end
  end

  def daily_report(conn, _params), do: invalid_reporting_date(conn)

  defp respond(conn, {:ok, report}), do: json(conn, %{data: report})

  defp respond(conn, :not_available) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "report_not_available"}})
  end

  defp invalid_reporting_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_reporting_date"}})
  end
end
