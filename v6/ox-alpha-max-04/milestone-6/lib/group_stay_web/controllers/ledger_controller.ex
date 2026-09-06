defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger
  alias GroupStayWeb.QueryDate

  def show(conn, params) do
    case QueryDate.parse(params["on"]) do
      {:ok, as_of} ->
        json(conn, %{data: Ledger.totals(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
