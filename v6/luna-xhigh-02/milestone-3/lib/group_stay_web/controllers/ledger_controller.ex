defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case parse_as_of(params) do
      {:ok, as_of} -> json(conn, %{data: Groups.ledger_totals(as_of)})
      :error -> invalid_date(conn)
    end
  end

  defp parse_as_of(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_as_of(%{"on" => _on}), do: :error

  defp parse_as_of(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
