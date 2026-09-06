defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def index(conn, params) do
    case GroupStayWeb.AsOf.parse(params) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Groups.ledger(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
