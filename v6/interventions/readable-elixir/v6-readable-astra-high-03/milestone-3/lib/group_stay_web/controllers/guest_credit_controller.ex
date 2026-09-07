defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  plug GroupStayWeb.Plugs.ExpiryDate

  def show(conn, %{"guest_id" => guest_id}) do
    json(conn, %{data: GroupStay.Credit.balance(guest_id, conn.assigns.expiry_on)})
  end
end
