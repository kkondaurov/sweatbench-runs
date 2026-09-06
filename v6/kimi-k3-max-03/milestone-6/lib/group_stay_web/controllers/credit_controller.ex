defmodule GroupStayWeb.CreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStayWeb.OnDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    on = OnDate.from_params(params)
    credit = Credit.guest_credit(guest_id, on)
    render(conn, :show, guest_id: guest_id, credit: credit)
  end
end
