defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStayWeb.Params

  def show(conn, %{"guest_id" => guest_id} = params) do
    json(conn, %{
      data: GroupStay.Groups.guest_credit_json(guest_id, Params.reporting_date(params))
    })
  end
end
