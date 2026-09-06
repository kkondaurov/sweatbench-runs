defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    json(conn, %{data: Groups.ledger(Groups.parse_as_of(params["on"]))})
  end
end
