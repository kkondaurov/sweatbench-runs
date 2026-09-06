defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get_group(group_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"error" => %{"code" => "group_not_found"}})

      group ->
        json(conn, %{"data" => Groups.serialize(group)})
    end
  end
end
