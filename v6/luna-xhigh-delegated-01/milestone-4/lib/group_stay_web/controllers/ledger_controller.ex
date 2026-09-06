defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Ledger

  def show(conn, params) do
    case parse_on(Map.get(params, "on")) do
      {:ok, as_of} -> json(conn, %{data: Ledger.read(as_of)})
      :error -> invalid_date(conn)
    end
  end

  defp parse_on(nil), do: {:ok, Date.utc_today()}

  defp parse_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_on(_value), do: :error

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
