defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger
  alias GroupStayWeb.QueryDate

  def show(conn, params) do
    case QueryDate.as_of(params) do
      {:ok, as_of} ->
        render(conn, :show, totals: Ledger.totals(as_of))

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_query"}})
    end
  end
end
