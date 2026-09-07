defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStayWeb.ReportingDate

  def show(conn, params) do
    case ReportingDate.from_params(params) do
      {:ok, on} -> json(conn, %{data: Reservations.ledger_totals(on)})
      {:error, :invalid_date} -> ReportingDate.render_error(conn)
    end
  end
end
