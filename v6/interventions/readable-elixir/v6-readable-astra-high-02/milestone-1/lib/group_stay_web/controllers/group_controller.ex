defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Reservations

  def show(conn, %{"group_id" => group_id}) do
    case Reservations.get_group(group_id) do
      {:ok, group} -> json(conn, %{data: GroupStayWeb.GroupJSON.data(group)})
      {:error, code} -> conn |> put_status(:not_found) |> json(%{error: %{code: code}})
    end
  end
end
