defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"guest_id" => guest_id} = params) do
    with {:ok, on} <- Operations.reporting_date(params["on"]) do
      json(conn, %{data: Operations.guest_credit(guest_id, on)})
    else
      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
