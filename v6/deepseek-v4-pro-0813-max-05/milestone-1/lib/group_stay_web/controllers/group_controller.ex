defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Groups

  def show(conn, %{"group_id" => group_id}) do
    case Groups.fetch_view(group_id) do
      {:ok, view} ->
        json(conn, %{data: view})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
