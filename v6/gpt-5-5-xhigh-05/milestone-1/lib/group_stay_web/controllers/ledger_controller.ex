defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.GroupReservations

  def show(conn, _params) do
    json(conn, %{data: GroupReservations.ledger_totals()})
  end
end
