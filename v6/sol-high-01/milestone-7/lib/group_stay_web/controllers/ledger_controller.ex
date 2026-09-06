defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, params) do
    case Bookings.ledger_data(params["on"]) do
      {:ok, data} ->
        json(conn, %{data: data})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
