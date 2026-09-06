defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def index(conn, _params) do
    json(conn, %{data: GroupStay.Reservations.ledger()})
  end
end
