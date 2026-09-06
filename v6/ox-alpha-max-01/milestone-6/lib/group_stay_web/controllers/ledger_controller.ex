defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger
  alias GroupStayWeb.Params

  def show(conn, params) do
    with {:ok, as_of} <- Params.parse_on(params) do
      json(conn, %{"data" => Ledger.global_totals(as_of)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
