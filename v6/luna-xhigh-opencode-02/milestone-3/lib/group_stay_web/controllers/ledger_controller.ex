defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case as_of(params) do
      {:ok, date} -> json(conn, %{data: Groups.ledger(date)})
      {:error, _reason} -> invalid_date(conn)
    end
  end

  defp as_of(%{"on" => on}), do: Date.from_iso8601(on)
  defp as_of(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
