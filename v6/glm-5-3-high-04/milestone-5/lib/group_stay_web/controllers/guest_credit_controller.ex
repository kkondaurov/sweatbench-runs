defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStay.Groups.resolve_as_on(params["on"]) do
      {:ok, as_on} ->
        json(conn, %{"data" => GroupStay.Groups.guest_credit(guest_id, as_on)})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
