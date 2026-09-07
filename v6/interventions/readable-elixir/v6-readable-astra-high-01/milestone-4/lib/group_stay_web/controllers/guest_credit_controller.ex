defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller
  alias GroupStay.Credits
  alias GroupStayWeb.ExpiryDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    case ExpiryDate.from_params(params) do
      {:ok, on} ->
        json(conn, %{data: Credits.for_guest(guest_id, on)})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
