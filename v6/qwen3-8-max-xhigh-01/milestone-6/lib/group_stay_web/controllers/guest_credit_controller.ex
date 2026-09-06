defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.AsOf

  def show(conn, %{"guest_id" => guest_id} = params) do
    case AsOf.fetch(params) do
      {:ok, as_of} ->
        json(conn, %{data: Groups.guest_credit(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
