defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found)

      group ->
        render(conn, :show, group: group)
    end
  end
end
