defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Reservations.guest_credit_data(guest_id, Map.get(params, "on"))})
  end
end
