defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller
  alias GroupStay.FinanceReporting

  def daily_report(conn, params) do
    with {:ok, date} <- FinanceReporting.parse_date(params["date"]),
         {:ok, report} <- FinanceReporting.daily_report(date) do
      json(conn, %{data: report})
    else
      {:error, %{code: code} = error} ->
        status = if code == "report_not_available", do: :not_found, else: :unprocessable_entity
        conn |> put_status(status) |> json(%{error: error})
    end
  end
end
