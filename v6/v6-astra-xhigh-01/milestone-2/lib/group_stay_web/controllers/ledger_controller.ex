defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Reservations.report_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Reservations.ledger(on)})

      {:error, :invalid_date} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
