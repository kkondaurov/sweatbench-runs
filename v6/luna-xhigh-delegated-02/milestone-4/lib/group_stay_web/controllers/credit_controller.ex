defmodule GroupStayWeb.CreditController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"guest_id" => guest_id} = params) do
    case Groups.parse_on(Map.get(params, "on")) do
      {:ok, on} -> json(conn, %{data: Groups.guest_credit(guest_id, on)})
      :error -> invalid_date(conn)
    end
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
