defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    case as_of_date(params) do
      {:ok, on} ->
        json(conn, %{data: Reservations.ledger_totals(on)})

      {:error, :invalid_date} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp as_of_date(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp as_of_date(%{"on" => _on}), do: {:error, :invalid_date}
  defp as_of_date(_params), do: {:ok, Date.utc_today()}
end
