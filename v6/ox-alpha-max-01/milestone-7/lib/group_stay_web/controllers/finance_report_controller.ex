defmodule GroupStayWeb.FinanceReportController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance
  alias GroupStayWeb.Params

  @moduledoc """
  Serves one day's finance report: how held cash moved per property and how
  the company-wide hotel-credit liability moved. Reading a report never
  changes state.

  A day published by a period close is served from its frozen snapshot, the
  exact bytes stored when the close committed, so no later operation, later
  close, or restart can move a single figure.
  """

  def show(conn, params) do
    case Params.parse_date(params["date"]) do
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_reporting_date"}})

      {:ok, date} ->
        case Finance.daily_report(date) do
          {:ok, {:published, data_json}} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(:ok, "{\"data\":" <> data_json <> "}")

          {:ok, report} ->
            json(conn, %{"data" => report})

          {:error, :report_not_available} ->
            conn
            |> put_status(:not_found)
            |> json(%{"error" => %{"code" => "report_not_available"}})
        end
    end
  end
end
