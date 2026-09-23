defmodule GroupStayWeb.Plugs.BodyParser do
  @moduledoc """
  `Plug.Parsers` that answers an unparseable request body with the API's error shape.

  The only endpoint that accepts a body is the partner batch endpoint, so a malformed body is
  reported as an invalid batch.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    Plug.Parsers.ParseError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(422, Jason.encode!(%{error: %{code: "invalid_batch"}}))
      |> halt()
  end
end
