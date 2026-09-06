defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Groups.get_guest_credit(guest_id, params["on"])})
  end
end
