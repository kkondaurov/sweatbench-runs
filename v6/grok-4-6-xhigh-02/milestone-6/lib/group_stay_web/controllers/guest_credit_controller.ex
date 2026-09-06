defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Credit.guest_credit(guest_id, Credit.as_of(params["on"]))})
  end
end
