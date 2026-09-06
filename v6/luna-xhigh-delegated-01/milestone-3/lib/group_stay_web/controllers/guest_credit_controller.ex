defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    case parse_on(Map.get(params, "on")) do
      {:ok, as_of} -> json(conn, %{data: Credit.read_guest(guest_id, as_of)})
      :error -> invalid_date(conn)
    end
  end

  defp parse_on(nil), do: {:ok, Date.utc_today()}

  defp parse_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_on(_value), do: :error

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
