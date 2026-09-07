defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Credits
  alias GroupStayWeb.ReportingDate

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- ReportingDate.from_params(params) do
      json(conn, %{data: Credits.guest_credit(guest_id, on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
