defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Groups.guest_credit(guest_id, Map.get(params, "on", Date.utc_today())) do
      {:ok, credit} ->
        json(conn, %{data: credit})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
