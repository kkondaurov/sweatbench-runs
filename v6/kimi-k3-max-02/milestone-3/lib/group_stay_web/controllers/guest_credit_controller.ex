defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups
  alias GroupStayWeb.OnParam

  def show(conn, %{"guest_id" => guest_id} = params) do
    case OnParam.parse(params) do
      {:ok, on_date} ->
        json(conn, %{data: Groups.guest_credit(guest_id, on_date)})

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
