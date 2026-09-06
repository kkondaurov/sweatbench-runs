defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, _params) do
    render(conn, :show, totals: Ledger.totals())
  end
end
