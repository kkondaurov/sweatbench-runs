defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"group_id" => group_id}) do
    case Groups.get(group_id) do
      {:ok, group} ->
        json(conn, %{data: Groups.serialize(group)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
