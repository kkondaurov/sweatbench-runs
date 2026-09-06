defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, as_of} <- as_of(params) do
      json(conn, %{data: Reservations.guest_credit(guest_id, as_of)})
    else
      :error -> invalid_date(conn)
    end
  end

  defp as_of(%{"on" => on}) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp as_of(%{"on" => _on}), do: :error
  defp as_of(_params), do: {:ok, Date.utc_today()}

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
