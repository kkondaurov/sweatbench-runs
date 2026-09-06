defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, _params) do
    json(conn, %{data: GroupStay.Batches.ledger()})
  end
end
