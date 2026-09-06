defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, params) do
    with {:ok, on} <- report_date(params) do
      json(conn, %{data: Operations.ledger(on)})
    else
      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp report_date(%{"on" => value}) when is_binary(value), do: Date.from_iso8601(value)
  defp report_date(%{"on" => _value}), do: {:error, :invalid_format}
  defp report_date(_params), do: {:ok, Date.utc_today()}
end
