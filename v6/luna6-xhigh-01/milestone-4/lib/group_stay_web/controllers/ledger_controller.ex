defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case as_of_date(params) do
      {:ok, date} -> json(conn, %{data: Reservations.ledger(date)})
      :error -> invalid_date(conn)
    end
  end

  defp as_of_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp as_of_date(params) do
    if Map.has_key?(params, "on"), do: :error, else: {:ok, Date.utc_today()}
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
