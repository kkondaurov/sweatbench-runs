defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, _params) do
    render(conn, :show, totals: Groups.ledger_totals())
  end
end
