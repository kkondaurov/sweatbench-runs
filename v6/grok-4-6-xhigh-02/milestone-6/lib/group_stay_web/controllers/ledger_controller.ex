defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStay.Groups

  def show(conn, params) do
    json(conn, %{data: Groups.ledger(Credit.as_of(params["on"]))})
  end
end
