defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.reporting_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: Operations.ledger(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
