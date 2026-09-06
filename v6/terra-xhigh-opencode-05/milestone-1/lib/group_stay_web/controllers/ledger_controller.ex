defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, _params) do
    json(conn, %{data: Reservations.ledger()})
  end
end
