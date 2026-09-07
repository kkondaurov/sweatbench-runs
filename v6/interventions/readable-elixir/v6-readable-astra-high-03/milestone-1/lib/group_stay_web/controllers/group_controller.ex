defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"group_id" => id}) do
    case Reservations.get_group(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: %{code: "group_not_found"}})
      group -> json(conn, %{data: GroupStayWeb.GroupJSON.data(group)})
    end
  end
end
