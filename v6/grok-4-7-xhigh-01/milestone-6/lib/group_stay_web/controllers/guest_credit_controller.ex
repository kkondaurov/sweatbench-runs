defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits
  alias GroupStayWeb.AsOf

  def show(conn, %{"guest_id" => guest_id} = params) do
    case AsOf.parse(params) do
      {:ok, on} ->
        json(conn, %{data: Credits.summary(guest_id, on)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
