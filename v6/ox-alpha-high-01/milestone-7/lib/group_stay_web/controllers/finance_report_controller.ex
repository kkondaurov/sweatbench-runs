defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStayWeb.Params

  def show(conn, params) do
    case Params.required_date(params) do
      {:ok, date} ->
        case GroupStay.Groups.daily_report(date) do
          {:ok, report} ->
            json(conn, %{data: report})

          {:error, :not_available} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "report_not_available"}})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_reporting_date"}})
    end
  end
end
