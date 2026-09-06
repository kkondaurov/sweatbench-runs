defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def index(conn, _params) do
    json(conn, %{data: Operations.ledger()})
  end
end
