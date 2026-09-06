defmodule GroupStayWeb.GuestsController do
  use GroupStayWeb, :controller

  def credit(conn, %{"guest_id" => guest_id} = params) do
    case GroupStay.guest_credit(guest_id, Map.get(params, "on")) do
      {:ok, credit} ->
        json(conn, %{"data" => credit})

      {:error, :invalid_date} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => %{"code" => "invalid_date"}})
    end
  end
end
