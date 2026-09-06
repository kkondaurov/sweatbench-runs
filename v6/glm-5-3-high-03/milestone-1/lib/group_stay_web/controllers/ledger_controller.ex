defmodule GroupStayWeb.LedgerController do
  @moduledoc """
  Reads the finance totals over all groups.
  """

  use GroupStayWeb, :controller

  def show(conn, _params) do
    json(conn, %{"data" => GroupStay.Groups.ledger_totals()})
  end
end
