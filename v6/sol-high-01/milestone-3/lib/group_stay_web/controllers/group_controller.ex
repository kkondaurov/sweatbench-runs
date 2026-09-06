defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Bookings

  def show(conn, %{"group_id" => group_id}) do
    case Bookings.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: Bookings.group_data(group)})

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})
    end
  end
end
