defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def daily_report(conn, %{"date" => value}) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, report} <- Operations.daily_finance_report(date) do
      json(conn, %{"data" => report})
    else
      {:error, :not_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "report_not_available"}})

      _ ->
        invalid_date(conn)
    end
  end

  def daily_report(conn, _params), do: invalid_date(conn)

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_reporting_date"}})
  end
end
