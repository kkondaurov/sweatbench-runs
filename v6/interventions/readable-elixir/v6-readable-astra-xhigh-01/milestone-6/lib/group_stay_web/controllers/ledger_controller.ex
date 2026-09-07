defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  plug GroupStayWeb.Plugs.CreditDate

  def show(conn, _params) do
    json(conn, %{data: GroupStay.Finance.totals(conn.assigns.credit_on)})
  end
end
