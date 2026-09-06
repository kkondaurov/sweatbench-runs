defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def show(conn, params) do
    with {:ok, on} <- OperationalCore.report_date(params["on"]) do
      json(conn, %{data: OperationalCore.ledger(on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
