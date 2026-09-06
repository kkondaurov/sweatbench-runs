defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    json(conn, %{data: Groups.ledger_totals(Groups.as_of_date(params["on"]))})
  end
end
