defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    GroupStayWeb.ReadDate.respond(conn, params, &GroupStay.ledger/1)
  end
end
