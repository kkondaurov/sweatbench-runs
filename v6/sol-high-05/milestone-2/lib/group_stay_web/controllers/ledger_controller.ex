defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case Groups.ledger(Map.get(params, "on", Date.utc_today())) do
      {:ok, ledger} ->
        json(conn, %{data: ledger})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
