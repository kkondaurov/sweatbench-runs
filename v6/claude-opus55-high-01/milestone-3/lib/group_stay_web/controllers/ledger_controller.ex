defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.AsOfDate

  def show(conn, params) do
    case AsOfDate.fetch(params) do
      {:ok, on} -> json(conn, %{data: Groups.ledger_totals(on)})
      :error -> AsOfDate.invalid(conn)
    end
  end
end
