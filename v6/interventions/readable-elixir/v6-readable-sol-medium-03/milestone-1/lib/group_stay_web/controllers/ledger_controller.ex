defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, _params), do: json(conn, %{data: Deposits.ledger()})
end
