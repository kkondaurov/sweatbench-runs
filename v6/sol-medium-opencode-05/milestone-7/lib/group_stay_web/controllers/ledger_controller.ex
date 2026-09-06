defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Operations.report_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Operations.ledger(on)})

      :error ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
