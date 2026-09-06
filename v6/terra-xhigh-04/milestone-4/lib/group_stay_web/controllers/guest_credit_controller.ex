defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- as_of_date(params) do
      json(conn, %{data: Credits.guest_credit(guest_id, on)})
    else
      :error -> invalid_on(conn)
    end
  end

  defp as_of_date(%{"on" => on}) when is_binary(on), do: Date.from_iso8601(on)
  defp as_of_date(%{"on" => _}), do: :error
  defp as_of_date(_params), do: {:ok, Date.utc_today()}

  defp invalid_on(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_on"}})
  end
end
