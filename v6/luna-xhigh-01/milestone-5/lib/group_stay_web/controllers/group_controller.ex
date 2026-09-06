defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      {:ok, group} ->
        json(conn, %{data: group})

      {:error, %{code: code}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: code}})
    end
  end
end
