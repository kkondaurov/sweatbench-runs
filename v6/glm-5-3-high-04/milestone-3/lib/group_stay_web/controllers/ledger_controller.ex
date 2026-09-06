defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Groups.resolve_as_on(params["on"]) do
      {:ok, as_on} ->
        json(conn, %{"data" => GroupStay.Groups.ledger_totals(as_on)})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
