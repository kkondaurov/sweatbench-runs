defmodule GroupStayWeb.Plugs.ExpiryDate do
  @moduledoc "Parses the optional expiry date shared by finance and guest-credit reads."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias GroupStay.Reservations.Operation

  def init(options), do: options

  def call(conn, _options) do
    case Map.fetch(conn.query_params, "on") do
      :error -> assign(conn, :expiry_date, Date.utc_today())
      {:ok, value} -> parse(conn, value)
    end
  end

  defp parse(conn, value) do
    case Operation.date(value) do
      {:ok, date} ->
        assign(conn, :expiry_date, date)

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
        |> halt()
    end
  end
end
