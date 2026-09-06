defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, _params) do
    render(conn, :show, totals: Deposits.ledger_totals())
  end
end
