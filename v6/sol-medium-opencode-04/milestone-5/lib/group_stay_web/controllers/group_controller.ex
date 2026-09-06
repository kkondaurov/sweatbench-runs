defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => %{"code" => "group_not_found"}})

      group ->
        json(conn, %{"data" => Reservations.group_json(group)})
    end
  end
end
