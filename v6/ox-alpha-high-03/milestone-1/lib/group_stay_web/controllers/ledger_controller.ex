defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def show(conn, _params) do
    json(conn, %{"data" => Finance.totals()})
  end
end
