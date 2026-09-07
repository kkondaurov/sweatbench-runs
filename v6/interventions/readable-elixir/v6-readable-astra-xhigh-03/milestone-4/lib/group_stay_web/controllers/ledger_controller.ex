defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  plug GroupStayWeb.Plugs.ExpiryDate

  def show(conn, _params) do
    json(conn, %{data: GroupStay.Reservations.ledger(conn.assigns.expiry_date)})
  end
end
