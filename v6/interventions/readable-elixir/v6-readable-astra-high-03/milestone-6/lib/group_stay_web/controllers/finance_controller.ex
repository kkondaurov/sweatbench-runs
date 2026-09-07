defmodule GroupStayWeb.FinanceController do
  use GroupStayWeb, :controller

  def daily_report(conn, params) do
    case GroupStay.Finance.daily_report(params["date"]) do
      {:ok, report} ->
        json(conn, %{data: report})

      {:error, code} ->
        status = if code == "invalid_reporting_date", do: :unprocessable_entity, else: :not_found
        conn |> put_status(status) |> json(%{error: %{code: code}})
    end
  end
end
