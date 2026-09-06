defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    json(conn, %{data: Reservations.ledger_totals(params["on"])})
  end
end
