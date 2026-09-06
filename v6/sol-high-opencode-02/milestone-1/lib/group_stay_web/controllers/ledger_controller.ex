defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, _params), do: json(conn, %{data: Bookings.ledger()})
end
