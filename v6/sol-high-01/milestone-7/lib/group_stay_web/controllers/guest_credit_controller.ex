defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Bookings.credit_data(guest_id, params["on"]) do
      {:ok, data} ->
        json(conn, %{data: data})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
