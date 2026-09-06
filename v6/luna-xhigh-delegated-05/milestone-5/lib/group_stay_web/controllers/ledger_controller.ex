defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.parse_as_of(params["on"]) do
      {:ok, as_of_date} ->
        json(conn, %{data: Operations.get_ledger(as_of_date)})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
