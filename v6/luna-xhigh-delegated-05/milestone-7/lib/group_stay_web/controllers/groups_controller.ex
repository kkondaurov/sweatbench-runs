defmodule GroupStayWeb.GroupsController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: group})
    end
  end
end
