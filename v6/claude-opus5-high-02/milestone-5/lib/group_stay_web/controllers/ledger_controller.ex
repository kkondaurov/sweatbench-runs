defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStayWeb.AsOf

  def show(conn, params) do
    case AsOf.fetch(params) do
      {:ok, on} ->
        render(conn, :show, totals: Reservations.ledger_totals(on))

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, code: "invalid_query")
    end
  end
end
