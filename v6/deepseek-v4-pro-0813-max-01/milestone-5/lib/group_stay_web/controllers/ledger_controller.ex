defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case as_on(params) do
      {:ok, on} ->
        json(conn, %{"data" => Groups.ledger(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end

  defp as_on(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp as_on(%{"on" => _not_a_date}), do: :error

  defp as_on(_params), do: {:ok, Date.utc_today()}
end
