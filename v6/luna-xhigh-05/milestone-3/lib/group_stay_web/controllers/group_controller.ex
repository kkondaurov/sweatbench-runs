defmodule GroupStayWeb.GroupController do
  use GroupStayWeb, :controller

  alias GroupStay.Operations

  def show(conn, %{"group_id" => group_id}) do
    case Operations.get_group(group_id) do
      {:ok, group} -> json(conn, %{data: group})
      {:error, :group_not_found} -> not_found(conn)
    end
  end

  def credit(conn, %{"guest_id" => guest_id} = params) do
    case Operations.get_guest_credit(guest_id, params["on"]) do
      {:ok, credit} -> json(conn, %{data: credit})
      {:error, :invalid_date} -> invalid_date(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "group_not_found"}})
  end

  defp invalid_date(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_date"}})
  end
end
