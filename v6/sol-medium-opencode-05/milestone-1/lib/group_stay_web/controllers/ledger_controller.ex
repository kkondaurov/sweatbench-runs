defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, _params) do
    json(conn, %{data: GroupStay.Operations.ledger()})
  end
end
