defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, params) do
    with {:ok, on} <- Bookings.read_date(params["on"]) do
      json(conn, %{data: Bookings.ledger(on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
