defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def show(conn, _params) do
    json(conn, %{data: OperationalCore.ledger()})
  end
end
