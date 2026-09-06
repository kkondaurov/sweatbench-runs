defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.fetch_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: group})

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
