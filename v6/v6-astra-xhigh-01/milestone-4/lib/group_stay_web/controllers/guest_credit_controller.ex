defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Reservations.report_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: Reservations.guest_credit(guest_id, on)})

      {:error, :invalid_date} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
