defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  plug GroupStayWeb.Plugs.ExpiryDate

  def show(conn, %{"guest_id" => guest_id}) do
    json(conn, %{data: Reservations.guest_credit(guest_id, conn.assigns.expiry_date)})
  end
end
