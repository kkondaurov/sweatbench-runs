defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, %{"group_id" => group_id}) do
    case Bookings.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: Bookings.serialize_group(group)})
    end
  end
end
