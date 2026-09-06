defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Finance

  def index(conn, _params) do
    json(conn, %{data: Finance.totals()})
  end
end
