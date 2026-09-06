defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, _params), do: json(conn, %{data: Operations.ledger()})
end
