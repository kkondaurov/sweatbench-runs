defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Reservations.get_guest_credit(guest_id, params["on"]) do
      {:ok, credit} ->
        json(conn, %{data: credit})

      {:error, :invalid_on} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_on"}})
    end
  end
end
