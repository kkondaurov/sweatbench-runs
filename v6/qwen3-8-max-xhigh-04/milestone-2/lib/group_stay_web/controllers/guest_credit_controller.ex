defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStayWeb.AsOfParam.parse(params) do
      {:ok, as_of} ->
        json(conn, %{data: Credit.guest_credit(guest_id, as_of)})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
