defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStayWeb.Params

  def show(conn, params) do
    json(conn, %{data: GroupStay.Groups.ledger_json(Params.reporting_date(params))})
  end
end
