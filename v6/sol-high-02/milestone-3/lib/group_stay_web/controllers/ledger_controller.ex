defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.ledger(params["on"]) do
      {:ok, ledger} ->
        json(conn, %{data: ledger})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
