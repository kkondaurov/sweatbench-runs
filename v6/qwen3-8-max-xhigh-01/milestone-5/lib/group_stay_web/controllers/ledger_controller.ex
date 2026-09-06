defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.AsOf

  def show(conn, params) do
    case AsOf.fetch(params) do
      {:ok, as_of} ->
        json(conn, %{data: Groups.ledger_totals(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
