defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case Groups.parse_read_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: Groups.ledger(on)})

      {:error, :date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
