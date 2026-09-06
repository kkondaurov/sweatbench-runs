defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStayWeb.AsOfDate.parse(params) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Groups.ledger_totals(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
