defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id, "on" => on}) do
    with {:ok, date} <- Date.from_iso8601(on) do
      json(conn, %{data: Reservations.guest_credit(guest_id, date)})
    else
      _ -> invalid_date(conn)
    end
  end

  def show(conn, %{"guest_id" => guest_id}) do
    json(conn, %{data: Reservations.guest_credit(guest_id)})
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
