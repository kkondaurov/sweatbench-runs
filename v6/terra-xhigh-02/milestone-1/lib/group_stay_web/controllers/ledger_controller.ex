defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, _params), do: json(conn, %{"data" => Groups.ledger()})
end
