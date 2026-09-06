defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  def show(conn, %{"group_id" => group_id}) do
    case GroupStay.Groups.fetch(group_id) do
      {:ok, group} ->
        json(conn, %{data: GroupStayWeb.GroupJSON.show(group)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
