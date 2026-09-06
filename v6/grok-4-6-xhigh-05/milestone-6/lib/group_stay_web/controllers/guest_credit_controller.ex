defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Groups.guest_credit(guest_id, Groups.parse_as_of(params["on"]))})
  end
end
