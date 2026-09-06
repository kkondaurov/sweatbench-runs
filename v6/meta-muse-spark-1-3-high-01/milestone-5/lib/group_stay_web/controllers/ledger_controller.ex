defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  def show(conn, params) do
    case parse_on(params) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Batches.ledger(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_operation"}})
    end
  end

  defp parse_on(params) do
    case Map.get(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, d} -> {:ok, d}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
