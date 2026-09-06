defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case Reservations.report_date(params) do
      {:ok, on} ->
        json(conn, %{"data" => Reservations.ledger(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
