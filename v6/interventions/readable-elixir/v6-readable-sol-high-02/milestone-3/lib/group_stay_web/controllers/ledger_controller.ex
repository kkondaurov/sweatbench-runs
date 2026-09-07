defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  alias GroupStayWeb.ReportingDate

  def show(conn, params) do
    case ReportingDate.parse(params) do
      {:ok, on} ->
        json(conn, %{"data" => Reservations.finance_totals(on)})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
