defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    with {:ok, on} <- GroupStay.Operations.read_date(params["on"]) do
      json(conn, %{data: GroupStay.Operations.ledger(on)})
    else
      :error ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
