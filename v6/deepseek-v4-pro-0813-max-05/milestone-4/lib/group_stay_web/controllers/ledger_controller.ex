defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  @doc """
  Returns the finance ledger. Accepts an optional `on=YYYY-MM-DD` query
  parameter to report credit expiry as of a given date; the current UTC
  date is used when it is omitted.
  """
  def show(conn, params) do
    with {:ok, on} <- Groups.as_of(params) do
      json(conn, %{data: Groups.ledger_totals(on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
