defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.OnDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{data: Groups.guest_credit(guest_id, OnDate.from_params(params))})
  end
end
