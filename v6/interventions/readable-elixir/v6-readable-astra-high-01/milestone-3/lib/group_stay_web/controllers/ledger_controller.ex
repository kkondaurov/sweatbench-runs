defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStayWeb.ExpiryDate.from_params(params) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Reservations.ledger(on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
