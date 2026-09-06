defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case GroupStay.Operations.parse_report_date(Map.get(params, "on")) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Operations.ledger_totals(on)})

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
