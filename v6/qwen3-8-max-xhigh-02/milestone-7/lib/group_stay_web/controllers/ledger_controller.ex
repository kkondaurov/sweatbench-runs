defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStayWeb.DateParam.parse(params["on"]) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Groups.ledger(as_of)})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
