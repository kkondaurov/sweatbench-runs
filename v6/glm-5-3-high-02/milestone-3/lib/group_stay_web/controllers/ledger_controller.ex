defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def index(conn, params) do
    case as_of(params) do
      {:ok, date} ->
        json(conn, %{data: Groups.ledger_totals(date)})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp as_of(%{"on" => on}) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_date}
    end
  end

  defp as_of(_params), do: {:ok, Date.utc_today()}
end
