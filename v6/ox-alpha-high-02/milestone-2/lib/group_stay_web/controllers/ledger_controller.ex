defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.OnDate

  def show(conn, params) do
    json(conn, %{data: Groups.ledger_totals(OnDate.from_params(params))})
  end
end
