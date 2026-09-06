defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, params) do
    with {:ok, on} <- reporting_date(params) do
      json(conn, %{data: Reservations.ledger(on)})
    else
      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp reporting_date(%{"on" => on}) when is_binary(on), do: Date.from_iso8601(on)
  defp reporting_date(%{"on" => _on}), do: {:error, :invalid_date}
  defp reporting_date(_params), do: {:ok, Date.utc_today()}
end
