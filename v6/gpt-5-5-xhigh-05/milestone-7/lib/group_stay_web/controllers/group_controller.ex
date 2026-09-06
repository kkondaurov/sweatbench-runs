defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.GroupReservations

  def show(conn, %{"group_id" => group_id}) do
    case GroupReservations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: GroupReservations.group_payload(group)})
    end
  end
end
