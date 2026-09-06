defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case Reservations.ledger_totals(params["on"]) do
      {:error, :invalid_on} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_on"}})

      totals ->
        json(conn, %{data: totals})
    end
  end
end
