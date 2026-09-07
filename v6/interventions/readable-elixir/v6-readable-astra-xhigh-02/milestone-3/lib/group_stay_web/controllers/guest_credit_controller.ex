defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  plug GroupStayWeb.Plugs.ExpiryDate

  def show(conn, %{"guest_id" => guest_id}) do
    json(conn, %{data: GroupStay.HotelCredit.balance(guest_id, conn.assigns.expiry_date)})
  end
end
