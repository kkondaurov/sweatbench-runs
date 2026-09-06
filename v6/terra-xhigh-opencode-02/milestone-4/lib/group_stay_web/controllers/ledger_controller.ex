defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    with {:ok, on} <- Groups.reporting_date(params) do
      json(conn, %{"data" => Groups.ledger(on)})
    else
      :error -> invalid_date(conn)
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"code" => "invalid_date"}})
  end
end
