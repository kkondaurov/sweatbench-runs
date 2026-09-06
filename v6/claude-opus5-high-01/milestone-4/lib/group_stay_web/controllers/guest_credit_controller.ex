defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credit
  alias GroupStayWeb.QueryDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case QueryDate.as_of(params) do
      {:ok, as_of} ->
        render(conn, :show, guest_id: guest_id, lots: Credit.available_lots(guest_id, as_of))

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_query"}})
    end
  end
end
