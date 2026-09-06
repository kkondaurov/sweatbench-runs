defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.OperationalCore

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- OperationalCore.report_date(params["on"]) do
      json(conn, %{data: OperationalCore.guest_credit(guest_id, on)})
    else
      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_date"}})
    end
  end
end
