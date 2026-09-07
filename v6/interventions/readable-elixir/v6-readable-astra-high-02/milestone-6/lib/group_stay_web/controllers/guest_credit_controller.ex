defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.ExpiryDate.parse(params) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Reservations.guest_credit(guest_id, on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
