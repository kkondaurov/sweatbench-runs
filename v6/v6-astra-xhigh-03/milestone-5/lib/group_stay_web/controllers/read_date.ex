defmodule GroupStayWeb.ReadDate do
  @moduledoc false
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  def respond(conn, params, read) do
    case parse(Map.get(params, "on", Date.to_iso8601(Date.utc_today()))) do
      {:ok, on} -> json(conn, %{data: read.(on)})
      _ -> conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end

  defp parse(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse(_), do: :error
end
