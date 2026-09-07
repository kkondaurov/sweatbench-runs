defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStayWeb.ReportingDate

  def show(conn, params) do
    with {:ok, on} <- ReportingDate.from_params(params) do
      json(conn, %{data: Reservations.ledger_totals(on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
