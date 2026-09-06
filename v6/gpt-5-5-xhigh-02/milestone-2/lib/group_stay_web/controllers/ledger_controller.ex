defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case Reservations.report_date_from_params(params) do
      {:ok, on_date} ->
        json(conn, %{data: Reservations.ledger_totals(on_date)})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
