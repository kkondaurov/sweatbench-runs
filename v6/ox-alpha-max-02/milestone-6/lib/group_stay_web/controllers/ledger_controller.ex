defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.DateParam

  def show(conn, params) do
    with {:ok, as_of} <- DateParam.reference_date(params["on"]) do
      json(conn, %{data: Groups.ledger_totals(as_of)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
