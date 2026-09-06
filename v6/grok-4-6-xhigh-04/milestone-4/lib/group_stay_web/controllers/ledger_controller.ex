defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    json(conn, %{data: Groups.ledger(params["on"])})
  end
end
