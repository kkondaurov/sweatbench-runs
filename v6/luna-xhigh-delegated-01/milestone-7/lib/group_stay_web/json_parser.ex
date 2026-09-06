defmodule GroupStayWeb.JSONParser do
  @moduledoc false

  import Plug.Conn

  def init(options), do: Plug.Parsers.init(options)

  def call(conn, options) do
    Plug.Parsers.call(conn, options)
  rescue
    Plug.Parsers.ParseError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: %{code: "invalid_json"}}))
      |> halt()
  end
end
