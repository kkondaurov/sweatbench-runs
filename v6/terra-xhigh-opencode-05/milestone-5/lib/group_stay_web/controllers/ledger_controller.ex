defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"on" => on}) do
    with {:ok, date} <- Date.from_iso8601(on) do
      json(conn, %{data: Reservations.ledger(date)})
    else
      _ -> invalid_date(conn)
    end
  end

  def show(conn, _params) do
    json(conn, %{data: Reservations.ledger()})
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
