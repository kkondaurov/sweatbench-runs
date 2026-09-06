defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations
  alias GroupStayWeb.AsOf

  def show(conn, %{"guest_id" => guest_id} = params) do
    case AsOf.fetch(params) do
      {:ok, on} ->
        render(conn, :show, credit: Reservations.guest_credit(guest_id, on))

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, code: "invalid_query")
    end
  end
end
