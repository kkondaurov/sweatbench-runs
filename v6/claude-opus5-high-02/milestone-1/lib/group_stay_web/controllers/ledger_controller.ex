defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, _params) do
    render(conn, :show, totals: Reservations.ledger_totals())
  end
end
