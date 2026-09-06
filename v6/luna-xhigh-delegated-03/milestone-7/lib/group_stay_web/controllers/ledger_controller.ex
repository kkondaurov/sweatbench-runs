defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.ledger(params) do
      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})

      ledger ->
        json(conn, %{data: ledger})
    end
  end
end
