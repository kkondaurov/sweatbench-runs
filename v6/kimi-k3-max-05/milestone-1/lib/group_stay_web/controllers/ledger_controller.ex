defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, _params) do
    json(conn, %{"data" => Ledger.totals()})
  end
end
