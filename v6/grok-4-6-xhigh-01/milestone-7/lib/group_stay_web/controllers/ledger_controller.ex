defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case parse_on(params["on"]) do
      {:ok, as_of} ->
        json(conn, %{data: Groups.ledger_totals(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp parse_on(nil), do: {:ok, Date.utc_today()}
  defp parse_on(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_on(_), do: :error
end
