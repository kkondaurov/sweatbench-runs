defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    case Operations.parse_report_date(params["on"]) do
      {:ok, as_of} -> json(conn, %{data: Operations.ledger_totals(as_of)})
      {:error, :invalid_date} -> invalid_date(conn)
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
