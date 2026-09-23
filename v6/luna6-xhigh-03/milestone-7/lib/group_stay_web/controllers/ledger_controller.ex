defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case report_date(params) do
      {:ok, on_date} ->
        json(conn, %{data: Groups.ledger_totals(on_date)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp report_date(%{"on" => value}), do: parse_date(value)
  defp report_date(_params), do: {:ok, Date.utc_today()}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error
end
