defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def index(conn, params) do
    with {:ok, on} <- Operations.reporting_date(params["on"]) do
      json(conn, %{data: Operations.ledger(on)})
    else
      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
