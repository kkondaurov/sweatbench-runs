defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    json(conn, %{data: Reservations.ledger_totals(Map.get(params, "on"))})
  end
end
