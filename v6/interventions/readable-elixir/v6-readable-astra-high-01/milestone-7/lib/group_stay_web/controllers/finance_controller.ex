defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller
  alias GroupStay.Finance

  def daily_report(conn, params) do
    with {:ok, date} <- Finance.reporting_date(params["date"]),
         {:ok, report} <- Finance.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, code} ->
        status = if code == "report_not_available", do: 404, else: 422
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
