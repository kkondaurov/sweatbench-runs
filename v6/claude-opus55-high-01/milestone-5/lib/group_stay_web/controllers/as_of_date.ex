defmodule GroupStayWeb.AsOfDate do
  @moduledoc """
  The optional `on=YYYY-MM-DD` query parameter used by reads that evaluate credit expiry.
  Without it, reads use the current UTC date.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def fetch(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  def fetch(%{"on" => _on}), do: :error
  def fetch(_params), do: {:ok, Date.utc_today()}

  def invalid(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
