defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.parse_as_of(Map.get(params, "on")) do
      {:ok, as_of} ->
        json(conn, %{data: Operations.ledger_totals(as_of)})

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
