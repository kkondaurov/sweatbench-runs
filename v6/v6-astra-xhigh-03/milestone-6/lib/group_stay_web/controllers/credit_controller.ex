defmodule GroupStayWeb.CreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    GroupStayWeb.ReadDate.respond(conn, params, &GroupStay.guest_credit(guest_id, &1))
  end
end
