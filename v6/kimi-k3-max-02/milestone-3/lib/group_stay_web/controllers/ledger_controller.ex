defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.OnParam

  def show(conn, params) do
    case OnParam.parse(params) do
      {:ok, on_date} ->
        json(conn, %{data: Groups.ledger_totals(on_date)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
