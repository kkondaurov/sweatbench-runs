defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.AsOf.parse(params) do
      {:ok, as_of} ->
        json(conn, %{data: GroupStay.Credit.guest_credit(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
