defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Reservations.guest_credit_data(guest_id, params["on"])})
  end
end
