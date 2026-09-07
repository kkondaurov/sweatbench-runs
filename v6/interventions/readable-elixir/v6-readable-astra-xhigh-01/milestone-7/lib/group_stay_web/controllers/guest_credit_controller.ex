defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  plug GroupStayWeb.Plugs.CreditDate

  def show(conn, %{"guest_id" => guest_id}) do
    json(conn, %{data: GroupStay.Credits.balance(guest_id, conn.assigns.credit_on)})
  end
end
