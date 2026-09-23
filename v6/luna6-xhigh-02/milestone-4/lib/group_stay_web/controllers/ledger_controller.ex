defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case parse_on(Map.get(params, "on")) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Groups.ledger_totals(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp parse_on(nil), do: {:ok, Date.utc_today()}

  defp parse_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_on(_), do: :error
end
