defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case GroupStayWeb.AsOfParam.parse(params) do
      {:ok, as_of} ->
        json(conn, %{data: Groups.ledger(as_of)})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
