defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay

  def show(conn, _params) do
    totals = GroupStay.finance_totals()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{data: GroupStayWeb.LedgerJSON.show(%{totals: totals})}))
  end
end
