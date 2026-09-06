defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Groups.parse_read_date(params["on"]) do
      {:ok, on} ->
        json(conn, %{data: Groups.guest_credit(guest_id, on)})

      {:error, :date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
