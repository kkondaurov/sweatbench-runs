defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Groups.guest_credit(guest_id, Groups.as_of_date(params["on"]))})
  end
end
