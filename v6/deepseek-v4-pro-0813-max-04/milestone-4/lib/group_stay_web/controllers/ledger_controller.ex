defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, params) do
    case on_date(params) do
      {:ok, date} ->
        json(conn, %{data: Deposits.ledger(date)})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp on_date(%{"on" => value}) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp on_date(_), do: {:ok, Date.utc_today()}
end
