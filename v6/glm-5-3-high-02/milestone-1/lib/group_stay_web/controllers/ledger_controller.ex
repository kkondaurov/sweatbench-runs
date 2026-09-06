defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def index(conn, _params) do
    json(conn, %{data: Groups.ledger_totals()})
  end
end
