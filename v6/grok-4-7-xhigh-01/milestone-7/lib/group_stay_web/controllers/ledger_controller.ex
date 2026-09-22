defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger
  alias GroupStayWeb.AsOf

  def show(conn, params) do
    case AsOf.parse(params) do
      {:ok, on} ->
        json(conn, %{data: Ledger.totals(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
