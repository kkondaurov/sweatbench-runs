defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.DateParam.parse(params["on"]) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Groups.guest_credit_view(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
