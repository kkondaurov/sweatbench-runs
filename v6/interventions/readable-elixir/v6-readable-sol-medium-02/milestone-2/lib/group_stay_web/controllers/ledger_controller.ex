defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    with {:ok, on} <- report_date(params) do
      json(conn, %{data: Reservations.ledger_totals(on)})
    else
      {:error, _reason} -> invalid_date(conn)
    end
  end

  defp report_date(%{"on" => value}), do: Date.from_iso8601(value)
  defp report_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
