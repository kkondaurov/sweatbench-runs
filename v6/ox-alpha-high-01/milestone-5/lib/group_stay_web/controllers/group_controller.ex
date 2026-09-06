defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  def show(conn, %{"group_id" => group_id}) do
    case GroupStay.Groups.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: GroupStay.Groups.group_json(group)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
