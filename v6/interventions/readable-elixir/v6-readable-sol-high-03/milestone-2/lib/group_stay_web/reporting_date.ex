defmodule GroupStayWeb.ReportingDate do
  @moduledoc false

  def from_params(%{"on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def from_params(%{"on" => _value}), do: {:error, :invalid_date}
  def from_params(_params), do: {:ok, Date.utc_today()}

  def render_error(conn) do
    conn
    |> Plug.Conn.put_status(:unprocessable_entity)
    |> Phoenix.Controller.json(%{error: %{code: "invalid_date"}})
  end
end
