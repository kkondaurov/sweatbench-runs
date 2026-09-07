defmodule GroupStayWeb.Plugs.ExpiryDate do
  @moduledoc """
  Parses the optional expiry reporting date shared by credit and ledger reads.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(options), do: options

  def call(conn, _options) do
    case Map.fetch(conn.query_params, "on") do
      :error -> assign(conn, :expiry_on, Date.utc_today())
      {:ok, value} -> parse(conn, value)
    end
  end

  defp parse(conn, value) do
    case GroupStay.Reservations.Booking.date(value) do
      {:ok, date} ->
        assign(conn, :expiry_on, date)

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
        |> halt()
    end
  end
end
