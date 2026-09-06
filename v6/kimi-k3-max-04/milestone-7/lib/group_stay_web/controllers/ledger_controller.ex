defmodule GroupStayWeb.LedgerController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, params) do
    case as_of(params) do
      {:ok, as_of} ->
        json(conn, %{data: Groups.ledger_totals(as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end

  # The optional `on=YYYY-MM-DD` query parameter selects the date used to
  # report credit expiry; without it the current UTC date is used.
  defp as_of(params) do
    case Map.get(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _other ->
        :error
    end
  end
end
