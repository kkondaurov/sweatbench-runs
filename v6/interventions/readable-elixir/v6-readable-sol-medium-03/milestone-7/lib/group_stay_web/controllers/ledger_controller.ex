defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits
  alias GroupStayWeb.ReportingDate

  def show(conn, params) do
    case ReportingDate.parse(params) do
      {:ok, on} ->
        json(conn, %{data: Deposits.ledger(on)})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
