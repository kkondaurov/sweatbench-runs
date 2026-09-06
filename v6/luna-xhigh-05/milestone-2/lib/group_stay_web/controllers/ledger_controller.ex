defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.ledger_totals(params["on"]) do
      totals when is_map(totals) -> json(conn, %{data: totals})
      {:error, :invalid_date} -> invalid_date(conn)
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
