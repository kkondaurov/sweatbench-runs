defmodule GroupStayWeb.DailyReportController do
  use GroupStayWeb, :controller

  alias GroupStay.FinanceReporting
  alias GroupStay.Operations

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case params do
      %{"date" => value} ->
        case Operations.parse_date(value) do
          {:ok, date} -> render_report(conn, date)
          :error -> error_json(conn, :unprocessable_entity, "invalid_reporting_date")
        end

      _ ->
        error_json(conn, :unprocessable_entity, "invalid_reporting_date")
    end
  end

  defp render_report(conn, date) do
    case FinanceReporting.daily_report(date) do
      {:ok, report} ->
        json(conn, %{data: report})

      :not_available ->
        error_json(conn, :not_found, "report_not_available")
    end
  end

  defp error_json(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
