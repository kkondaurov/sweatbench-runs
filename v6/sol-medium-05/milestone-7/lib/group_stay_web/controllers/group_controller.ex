defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Deposits

  def show(conn, %{"group_id" => group_id}) do
    case Deposits.get_group(group_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "group_not_found"}})

      group ->
        json(conn, %{data: Deposits.group_data(group)})
    end
  end
end
