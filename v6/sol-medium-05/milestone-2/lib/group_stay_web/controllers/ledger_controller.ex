defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, params) do
    case reporting_date(params) do
      {:ok, on} ->
        json(conn, %{data: Deposits.ledger(on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp reporting_date(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp reporting_date(%{"on" => _value}), do: :error
  defp reporting_date(_params), do: {:ok, Date.utc_today()}
end
