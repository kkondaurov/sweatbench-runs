defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.OnDate

  def show(conn, params) do
    on = OnDate.from_params(params)
    render(conn, :show, totals: Groups.ledger_totals(on))
  end
end
