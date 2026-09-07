defmodule GroupStayWeb.Plugs.CreditDate do
  @moduledoc "Parses the optional expiry evaluation date shared by credit and ledger reads."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(options), do: options

  def call(conn, _options) do
    case parse(conn.query_params) do
      {:ok, date} ->
        assign(conn, :credit_on, date)

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
        |> halt()
    end
  end

  defp parse(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse(%{"on" => _}), do: :error
  defp parse(_params), do: {:ok, Date.utc_today()}
end
