defmodule GroupStayWeb.GuestCreditController do
  use GroupStayWeb, :controller

  def show(conn, %{"guest_id" => guest_id} = params) do
    case GroupStay.Operations.parse_report_date(Map.get(params, "on")) do
      {:ok, on} ->
        json(conn, %{data: GroupStay.Operations.guest_credit(guest_id, on)})

      {:error, code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end
end
