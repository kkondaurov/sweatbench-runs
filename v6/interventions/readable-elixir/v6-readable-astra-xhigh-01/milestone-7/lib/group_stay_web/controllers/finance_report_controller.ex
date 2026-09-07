defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance.Reporting
  alias GroupStay.Reservations.Operation

  def show(conn, params) do
    with {:ok, date} <- Operation.date(params["date"], "invalid_reporting_date"),
         {:ok, report} <- Reporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, code} ->
        status = if code == "invalid_reporting_date", do: :unprocessable_entity, else: :not_found
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
