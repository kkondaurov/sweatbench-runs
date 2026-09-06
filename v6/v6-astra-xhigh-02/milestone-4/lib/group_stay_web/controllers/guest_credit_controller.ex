defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStay.Reservations.read_date(params) do
      {:ok, on} -> json(conn, %{data: GroupStay.Reservations.guest_credit(guest_id, on)})
      {:error, error} -> conn |> put_status(:unprocessable_entity) |> json(%{error: error})
    end
  end
end
