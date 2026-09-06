defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay

  def show(conn, %{"group_id" => group_id}) do
    case GroupStay.get_group_with_rooms(group_id) do
      {:ok, group} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{data: GroupStayWeb.GroupJSON.show(%{group: group})}))

      {:error, :group_not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: %{code: "group_not_found"}}))
    end
  end
end
