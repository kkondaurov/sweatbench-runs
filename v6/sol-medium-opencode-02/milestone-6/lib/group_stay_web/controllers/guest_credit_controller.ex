defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Operations.as_of_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{"data" => Operations.guest_credit(guest_id, on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
