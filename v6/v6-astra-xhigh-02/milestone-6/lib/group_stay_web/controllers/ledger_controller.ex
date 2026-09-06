defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def index(conn, params) do
    case GroupStay.Reservations.read_date(params) do
      {:ok, on} -> json(conn, %{data: GroupStay.Reservations.ledger(on)})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{error: error})
    end
  end
end
